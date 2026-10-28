# OpenAI API adapter.
# API docs: https://platform.openai.com/docs/api-reference/chat
module Llm
  class OpenaiAdapter
    BASE_URL = "https://api.openai.com/v1"

    # HTTParty timeouts (seconds): open_timeout for TCP handshake, timeout for read.
    OPEN_TIMEOUT = 10
    # Generous read timeout: local models (Bonsai/Ollama) can take minutes to
    # process large prompts on CPU, and long agentic tool-turn generations
    # legitimately run long. Remote APIs answer earlier and are unaffected.
    READ_TIMEOUT = 600

    # Transient-failure resilience. A local llama.cpp server can briefly be
    # unreachable (crash + watchdog restart, laptop wake, socket reset). Retry
    # connection-level errors with a short backoff instead of failing the run.
    MAX_RETRIES = 3
    RETRY_BACKOFF = 2 # seconds, multiplied by the attempt number
    TRANSIENT_ERRORS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout,
      EOFError, IOError
    ].freeze

    # "Server isn't there" is NOT worth a long retry loop: if nothing is
    # listening we fail fast (one quick retry for a watchdog restart) and raise
    # an actionable error, rather than stalling the request for ~12s. Mid-stream
    # resets/timeouts keep the more generous MAX_RETRIES budget above.
    CONNECTION_ERRORS = [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH ].freeze
    MAX_CONNECT_RETRIES = 1
    CONNECT_BACKOFF = 0.5

    # Streaming responses are judged by their status line, not by what the body
    # happens to parse into: only 2xx is a stream, anything else is a gateway
    # failure. Error bodies are kept (truncated) so the raised message carries
    # the provider's own reason instead of a bare status code.
    SUCCESS_STATUSES = (200..299).freeze
    MAX_ERROR_BODY = 500

    attr_reader :api_key, :model, :base_url, :top_p

    def initialize(api_key:, model:, base_url: nil, top_p: nil)
      @api_key = api_key
      @model = model
      @base_url = base_url || BASE_URL
      @top_p = top_p
    end

    def chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, stream: false)
      Rails.logger.info "[shams] chat model=#{model} tools=#{tools.present?} stream=#{stream}"
      if stream
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      else
        sync_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      end
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, &block)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)
      body[:stream] = true
      body[:stream_options] = { include_usage: true }

      full_content = +""
      reasoning = +""
      tool_calls = []
      usage_tokens = nil
      attempt = 0

      begin
        attempt += 1
        # Reset buffers on each (re)attempt so a retry replays from scratch.
        full_content = +""
        reasoning = +""
        tool_calls = []
        usage_tokens = nil
        stream_status = nil
        error_body = +""

        response = HTTParty.post("#{base_url}/chat/completions",
          headers: headers,
          body: body.to_json,
          stream_body: true,
          timeout: READ_TIMEOUT,
          open_timeout: OPEN_TIMEOUT
        ) do |chunk|
          # While streaming, HTTParty yields a ResponseFragment that exposes the
          # numeric status line as soon as the headers arrive, so the turn is
          # judged on the real HTTP result instead of on what the body happens
          # to parse into. A gateway failure is not an SSE stream: OpenRouter
          # answers a 429 with plain JSON, which used to yield no "data:" lines
          # at all, and the run "succeeded" with an empty reply - the model was
          # blamed for the provider's outage. Keep the server's own reason and
          # skip the parse.
          status = status_of(chunk)
          if status
            stream_status = status
            unless SUCCESS_STATUSES.cover?(status)
              error_body << chunk.to_s if error_body.bytesize < MAX_ERROR_BODY
              next
            end
          end

          chunk.to_s.each_line do |line|
            line = line.chomp
            next unless line.start_with?("data: ")
            data = line.delete_prefix("data: ")
            next if data == "[DONE]"

            begin
              event = JSON.parse(data)

              # The authoritative usage arrives on the final chunk (empty
              # "choices"). Capture it so the reported token count matches the
              # server instead of a chars/4 guess.
              usage_tokens = event.dig("usage", "completion_tokens") if event["usage"]

              choice = event.dig("choices", 0)
              next unless choice

              delta = choice["delta"] || {}

              # Reasoning models emit chain-of-thought before any visible
              # "content": llama.cpp under "reasoning_content", OpenRouter-style
              # gateways under "reasoning". Tag either as a "reasoning" frame so
              # the UI can show a live "thinking" phase during the long
              # pre-answer wait instead of a dead spinner. The payload is never
              # answer text - Agents::AgentRunner drops it and forwards only a
              # status, and nothing here may substitute it into the reply.
              thought = delta["reasoning_content"].presence || delta["reasoning"].presence
              if thought
                reasoning << thought
                yield(thought, reasoning, tool_calls, "reasoning") if block_given?
              end

              if delta["content"]
                full_content << delta["content"]
                yield(delta["content"], full_content, tool_calls, "content") if block_given?
              end

              if delta["tool_calls"]
                delta["tool_calls"].each do |tc|
                  if tc["index"] && tool_calls[tc["index"]]
                    tool_calls[tc["index"]][:function][:arguments] << tc.dig("function", "arguments").to_s
                  else
                    tool_calls << {
                      id: tc["id"],
                      type: "function",
                      function: { name: tc.dig("function", "name"), arguments: tc.dig("function", "arguments").to_s }
                    }
                  end
                end
              end
            rescue JSON::ParserError
              next
            end
          end
        end

        # Error bodies and healthy streams both arrive through the fragment
        # block above, but a response that streams no fragments at all leaves
        # stream_status unset - the completed response still carries the status
        # line, so read it there. nil means the transport never told us (a stub
        # that yields bare String chunks does exactly this), which counts as
        # unknown, not as a failure.
        stream_status ||= status_of(response)
        if stream_status && !SUCCESS_STATUSES.cover?(stream_status)
          raise stream_error(stream_status, error_body)
        end
      rescue *TRANSIENT_ERRORS => e
        # Only safe to retry before anything was streamed to the caller.
        conn = CONNECTION_ERRORS.include?(e.class)
        max_attempts = conn ? (MAX_CONNECT_RETRIES + 1) : MAX_RETRIES
        backoff = conn ? CONNECT_BACKOFF : RETRY_BACKOFF
        if full_content.empty? && tool_calls.empty? && attempt < max_attempts
          Rails.logger.warn "[shams] stream retry #{attempt}/#{max_attempts} after #{e.class}: #{e.message.to_s[0, 120]}"
          sleep(backoff * attempt)
          retry
        end
        raise provider_error(e)
      end

      # A stream can end without any visible content - a reasoning model that
      # spent the whole completion budget thinking, or a gateway that answered
      # with something other than events. Blank stays blank: AgentStreamJob
      # marks the row metadata["empty_response"] and the UI tells the user the
      # agent returned no text. Substituting the chain of thought here is what
      # used to paste private reasoning into the answer bubble as if it were
      # the reply, so it deliberately does not happen.
      { content: full_content, tool_calls: tool_calls,
        tokens: usage_tokens || estimate_tokens(full_content) }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)

      response = post_json("#{base_url}/chat/completions", body)

      unless response.success?
        Rails.logger.error "[shams] ERROR #{response.code} - #{response.body.truncate(500)}"
        raise LlmError, "OpenAI API error: #{response.code} - #{response.body}"
      end

      data = JSON.parse(response.body)
      choice = data.dig("choices", 0, "message") || {}

      # Only the visible answer is the reply. Reasoning-capable models keep
      # their thinking in "reasoning_content" (llama.cpp) or "reasoning"
      # (OpenRouter-style gateways) and can spend the whole completion budget
      # there, leaving content empty; that is an empty answer, and the caller
      # records metadata["empty_response"] so the UI says so. Falling back to
      # the thinking text was a live defect - a truncated Recursive Flint turn
      # returned its entire internal monologue as the message body.
      content = choice["content"]

      raw_tool_calls = choice["tool_calls"] || []

      tool_calls = raw_tool_calls.map.with_index do |tc, i|
        { id: tc["id"].presence || SecureRandom.hex(16), type: "function", function: tc["function"] }
      end

      {
        content: content.to_s,
        tool_calls: tool_calls,
        tokens: data.dig("usage", "completion_tokens") || estimate_tokens(content),
        finish_reason: data.dig("choices", 0, "finish_reason") || "stop"
      }
    end

    def embeddings(text)
      response = post_json("#{base_url}/embeddings",
        { model: "text-embedding-3-small", input: text, encoding_format: "float" })

      unless response.success?
        raise LlmError, "OpenAI Embedding error: #{response.code}"
      end

      data = JSON.parse(response.body)
      data.dig("data", 0, "embedding")
    end

    private

    # HTTParty POST with retry + linear backoff for transient connection
    # errors (server restarting, socket reset, timeouts). Non-idempotent
    # generation is acceptable to replay here because a connection-level
    # failure means the request never completed on the server side.
    def post_json(url, body)
      attempt = 0
      begin
        attempt += 1
        HTTParty.post(url,
          headers: headers,
          body: body.to_json,
          timeout: READ_TIMEOUT,
          open_timeout: OPEN_TIMEOUT
        )
      rescue *TRANSIENT_ERRORS => e
        conn = CONNECTION_ERRORS.include?(e.class)
        max_attempts = conn ? (MAX_CONNECT_RETRIES + 1) : MAX_RETRIES
        backoff = conn ? CONNECT_BACKOFF : RETRY_BACKOFF
        if attempt < max_attempts
          Rails.logger.warn "[shams] retry #{attempt}/#{max_attempts} after #{e.class}: #{e.message.to_s[0, 120]}"
          sleep(backoff * attempt)
          retry
        end
        raise provider_error(e)
      end
    end

    def build_request_body(messages, tools, temperature, max_tokens, top_p = nil)
      body = {
        model: model,
        messages: messages.map { |m| format_message(m) },
        temperature: temperature,
        max_tokens: max_tokens
      }
      body[:top_p] = top_p unless top_p.nil?

      if tools.any?
        body[:tools] = tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name],
              description: tool[:description] || "",
              parameters: tool[:parameters] || { type: "object", properties: {}, required: [] }
            }
          }
        end
      end

      body
    end

    def format_message(msg)
      formatted = { role: msg[:role], content: msg[:content].to_s }

      if msg[:role] == "tool"
        formatted[:tool_call_id] = msg[:tool_call_id]
      elsif msg[:role] == "assistant" && (msg[:tool_calls] || msg[:tool_call_id])
        formatted[:tool_calls] = msg[:tool_calls]
      end

      formatted
    end

    def headers
      {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json"
      }
    end

    # The numeric HTTP status of a streaming turn. HTTParty yields a
    # ResponseFragment that delegates the chunk text but also answers #code, and
    # the completed response answers #code too; a bare String chunk (what test
    # stubs yield) answers neither, so the caller gets nil and treats the status
    # as unknown instead of inventing one.
    def status_of(source)
      return nil unless source.respond_to?(:code)

      Integer(source.code.to_s, 10)
    rescue ArgumentError
      nil
    end

    # A non-2xx streaming turn is a provider failure, not an empty answer. Say
    # which endpoint refused, with the reason it gave, so the run is recorded
    # failed with something actionable instead of a blank message.
    def stream_error(status, error_body)
      reason = error_body.to_s.strip[0, MAX_ERROR_BODY]
      Rails.logger.error "[shams] ERROR #{status} - #{reason.presence || "(empty body)"}"
      detail = reason.presence ? ": #{reason}" : " with no response body"
      LlmError.new("Model server at #{base_url} answered HTTP #{status}#{detail}.")
    end

    def provider_error(e)
      if CONNECTION_ERRORS.include?(e.class)
        LlmError.new("Could not reach the model server at #{base_url} (#{e.class}). " \
                     "Check that the local LLM server is running and listening on this port.")
      else
        LlmError.new("The model server at #{base_url} did not respond in time (#{e.class}).")
      end
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    class LlmError < StandardError; end
  end
end
