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

        HTTParty.post("#{base_url}/chat/completions",
          headers: headers,
          body: body.to_json,
          stream_body: true,
          timeout: READ_TIMEOUT,
          open_timeout: OPEN_TIMEOUT
        ) do |chunk|
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
