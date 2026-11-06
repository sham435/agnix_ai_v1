# Anthropic Claude API adapter.
# API docs: https://docs.anthropic.com/en/api/messages
module Llm
  class AnthropicAdapter
    BASE_URL = "https://api.anthropic.com/v1"

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120

    # A streaming turn is judged by its status line, not by what the body happens
    # to parse into: only 2xx is a response, anything else is a gateway or API
    # failure. The error body is kept (truncated) so the raised message carries
    # Anthropic's own complaint instead of a bare status code.
    SUCCESS_STATUSES = (200..299).freeze
    MAX_ERROR_BODY = 500

    # We keep more of the error body than we show. MAX_ERROR_BODY bounds the
    # single-line reason echoed into the raised message, but classification
    # (parsing error.type and the credit sniff) needs the provider's full JSON,
    # which can run past that display window. Retaining up to this many bytes
    # for parsing keeps an out-of-credit 400 from being misfiled as a generic
    # rejection just because its message happened to be long.
    ERROR_CLASSIFY_LIMIT = 2_048

    # Transient-failure resilience, mirroring Llm::OpenaiAdapter. A brief
    # capacity/timeout blip (429/5xx, socket reset) is worth replaying with a
    # short backoff, but a permanent rejection (bad key, empty credit, oversized
    # request) is not - that surfaces as a typed, non-retryable LlmError so the run
    # fails fast and the UI can point the user at the real cause.
    MAX_RETRIES = 3
    RETRY_BACKOFF = 2 # seconds, multiplied by the attempt number
    MAX_CONNECT_RETRIES = 1 # "nothing is listening" fails fast, not after ~12s
    CONNECT_BACKOFF = 0.5
    RETRY_AFTER_MAX = 30 # ceiling on a provider Retry-After we are willing to sleep

    TRANSIENT_ERRORS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ENETDOWN, Errno::EPIPE, Net::OpenTimeout,
      Net::ReadTimeout, EOFError, IOError, SocketError, Net::HTTPBadResponse
    ].freeze

    CONNECTION_ERRORS = [
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
      Errno::ENETDOWN, SocketError
    ].freeze

    # Anthropic's documented status -> (code, retryable) table. Everything 4xx
    # except 429 is permanent (redelivering a bad key or empty credit can't help);
    # throttling and 5xx/capacity faults are transient and worth replaying.
    STATUS_CODES = {
      400 => [ :provider_request_rejected, false ],
      401 => [ :provider_authentication_failed, false ],
      402 => [ :provider_credit_insufficient, false ],
      403 => [ :provider_permission_denied, false ],
      404 => [ :provider_model_not_found, false ],
      409 => [ :provider_conflict, false ],
      413 => [ :provider_request_too_large, false ],
      429 => [ :provider_rate_limited, true ],
      500 => [ :provider_unavailable, true ],
      502 => [ :provider_unavailable, true ],
      503 => [ :provider_unavailable, true ],
      504 => [ :provider_timeout, true ],
      529 => [ :provider_overloaded, true ]
    }.freeze

    # The provider's own structured error.type is more specific than the status
    # bucket, so it wins over the status when present.
    ERROR_TYPE_CODES = {
      "authentication_error"  => [ :provider_authentication_failed, false ],
      "billing_error"         => [ :provider_credit_insufficient, false ],
      "permission_error"      => [ :provider_permission_denied, false ],
      "not_found_error"       => [ :provider_model_not_found, false ],
      "conflict_error"        => [ :provider_conflict, false ],
      "request_too_large"     => [ :provider_request_too_large, false ],
      "invalid_request_error" => [ :provider_request_rejected, false ],
      "rate_limit_error"      => [ :provider_rate_limited, true ],
      "overloaded_error"      => [ :provider_overloaded, true ],
      "timeout_error"         => [ :provider_timeout, true ],
      "api_error"             => [ :provider_unavailable, true ]
    }.freeze

    # Anthropic documents that a reached spending/credit ceiling can surface as a
    # 400 invalid_request_error, so a bare status/type map would misfile an
    # out-of-credit key as a generic bad request. Sniff the message text to upgrade
    # those to :provider_credit_insufficient - the exact defect this fixes.
    CREDIT_MESSAGE_PATTERNS = /credit balance|insufficient credits|out of funded credits|funded credits|spending limit|exceeded your (?:current )?(?:budget|spending)|payment (?:required|needed|problem)|billing/.freeze

    attr_reader :api_key, :model

    def initialize(api_key:, model:)
      @api_key = api_key
      @model = model
    end

    def chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, stream: false)
      if stream
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      else
        sync_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      end
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, &block)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)
      body[:stream] = true

      attempt = 0
      streamed_any = false
      begin
        attempt += 1
        do_stream_chat(body) do |*args|
          # Replay guard (§4a): once real content has reached the consumer,
          # re-running the attempt would duplicate what the user already saw, so
          # only a failure that streamed nothing may be retried.
          streamed_any = true if args.first.to_s != ""
          block&.call(*args)
        end
      rescue *TRANSIENT_ERRORS => e
        if !streamed_any && attempt < retry_budget_for(e)
          Rails.logger.warn "[shams] anthropic stream retry #{attempt}/#{retry_budget_for(e)} after #{e.class}"
          sleep(backoff_for(e) * attempt)
          retry
        end
        # If text already reached the consumer we deliberately did not replay,
        # so the error must not claim replay would help either - a downstream
        # that honors retryable? would re-run the turn and duplicate the reply.
        raise provider_error(e, retryable: !streamed_any)
      rescue LlmError => e
        if e.retryable? && !streamed_any && attempt < MAX_RETRIES
          Rails.logger.warn "[shams] anthropic stream retry #{attempt}/#{MAX_RETRIES} after HTTP #{e.status} #{e.code}"
          sleep(retry_wait(e, attempt))
          retry
        end
        raise(streamed_any ? non_replayable(e) : e)
      end
    end

    # One streaming attempt. Accumulates and yields deltas, and raises a typed
    # LlmError for any rejection so the wrapper above can decide whether the
    # failure is worth replaying.
    def do_stream_chat(body)
      full_content = +""
      tool_calls = []
      raw = +""
      saw_sse = false
      stream_status = nil
      error_body = +""
      finish_reason = nil

      response = HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json,
        stream_body: true,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
      ) do |chunk|
        # HTTParty yields a ResponseFragment while streaming, which answers
        # #code as soon as the headers arrive. A rejection is not an SSE stream
        # - Anthropic answers 4xx/5xx with one JSON object, a proxy may answer
        # with HTML - so keep the reason, skip the parse, and fail below instead
        # of finalizing the turn as an empty reply.
        status = status_of(chunk)
        if status
          stream_status = status
          unless SUCCESS_STATUSES.cover?(status)
            error_body << chunk.to_s if error_body.bytesize < ERROR_CLASSIFY_LIMIT
            next
          end
        end

        raw << chunk.to_s
        chunk.to_s.each_line do |line|
          line = line.chomp
          next unless line.start_with?("data: ")
          saw_sse = true
          data = line.delete_prefix("data: ")
          next if data == "[DONE]"

          begin
            event = JSON.parse(data)
            case event["type"]
            when "content_block_start"
              block_data = event["content_block"]
              if block_data["type"] == "tool_use"
                tool_calls << {
                  id: block_data["id"],
                  type: "function",
                  function: {
                    name: block_data["name"],
                    arguments: block_data["input"].to_json
                  }
                }
              end
            when "content_block_delta"
              delta = event["delta"]
              if delta["type"] == "text_delta"
                text = delta["text"]
                full_content << text
                yield(text, full_content, tool_calls) if block_given?
              elsif delta["type"] == "input_json_delta"
                # Tool call arguments accumulating.
                if tool_calls.any?
                  last_tool = tool_calls.last
                  args = JSON.parse(last_tool[:function][:arguments] + delta["partial_json"]) rescue nil
                  last_tool[:function][:arguments] = (last_tool[:function][:arguments] + delta["partial_json"]) if args.nil?
                end
              end
            when "content_block_stop"
              # Tool call finished.
            when "message_delta"
              # Final metadata: the terminal stop_reason lives here. "max_tokens"
              # means the reply was cut off at the cap - normalize it to "length"
              # so the runner's truncation check is provider-agnostic.
              stop_reason = event.dig("delta", "stop_reason")
              finish_reason = stop_reason == "max_tokens" ? "length" : stop_reason if stop_reason
            end
          rescue JSON::ParserError
            next
          end
        end
      end

      # If the transport yielded no fragments at all, the status HTTParty
      # reports once the request finishes is the only signal. A status it never
      # reported stays unknown instead of being invented as a failure.
      stream_status ||= status_of(response)
      if stream_status && !SUCCESS_STATUSES.cover?(stream_status)
        raise stream_error(stream_status, error_body, retry_after: retry_after_seconds(response))
      end

      # Buffered-response fallback. We ask for a stream, but some gateways and
      # models ignore stream:true and return one complete JSON message. Without
      # this the SSE parser yields nothing and the turn looks "empty". Parse the
      # raw body as a non-streaming message and surface its text as a single
      # content delta so streaming consumers still receive genuine tokens.
      if !saw_sse && full_content.empty? && tool_calls.empty? && !raw.empty?
        parsed = (JSON.parse(raw) rescue nil)

        # A rejected request (bad key, out of credit, unknown model) also arrives
        # as one JSON object — but an error, not a message. The SSE parser finds
        # no deltas, so without this the turn finalizes as an empty reply and the
        # UI blames the user's phrasing while the provider's actual complaint is
        # thrown away. Raise instead: the runner records it on the run and on the
        # message metadata.
        if parsed.is_a?(Hash) && parsed["type"] == "error"
          err = parsed["error"].is_a?(Hash) ? parsed["error"] : {}
          detail = err["message"].to_s.presence ||
                   err["type"].to_s.presence ||
                   raw.to_s.truncate(300)
          code, retryable = classify(nil, err["type"], err["message"])
          raise LlmError.new("Anthropic API error: #{detail}",
            code: code, retryable: retryable, provider_error_type: err["type"].to_s.presence)
        end

        # A complete message carries its own terminal stop_reason at the top
        # level; keep it so a buffered truncated reply is flagged too.
        stop_reason = parsed["stop_reason"] if parsed.is_a?(Hash)
        finish_reason = stop_reason == "max_tokens" ? "length" : stop_reason if stop_reason

        Array(parsed&.dig("content")).each do |part|
          case part["type"]
          when "text"
            text = part["text"].to_s
            next if text.empty?

            full_content << text
            yield(full_content, full_content, tool_calls) if block_given?
          when "tool_use"
            tool_calls << {
              id: part["id"],
              type: "function",
              function: { name: part["name"], arguments: part["input"].to_json }
            }
          end
        end
      end

      { content: full_content, tool_calls: tool_calls,
        tokens: estimate_tokens(full_content), finish_reason: finish_reason || "stop" }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      body = build_request_body(messages, tools, temperature, max_tokens, top_p)

      attempt = 0
      begin
        attempt += 1
        do_sync_chat(body)
      rescue *TRANSIENT_ERRORS => e
        if attempt < retry_budget_for(e)
          Rails.logger.warn "[shams] anthropic sync retry #{attempt}/#{retry_budget_for(e)} after #{e.class}"
          sleep(backoff_for(e) * attempt)
          retry
        end
        raise provider_error(e)
      rescue LlmError => e
        if e.retryable? && attempt < MAX_RETRIES
          Rails.logger.warn "[shams] anthropic sync retry #{attempt}/#{MAX_RETRIES} after HTTP #{e.status} #{e.code}"
          sleep(retry_wait(e, attempt))
          retry
        end
        raise e
      end
    end

    # One non-streaming request. Raises a typed LlmError for a rejection so
    # sync_chat can decide whether the failure is worth replaying.
    def do_sync_chat(body)
      response = HTTParty.post("#{BASE_URL}/messages",
        headers: headers,
        body: body.to_json,
        timeout: READ_TIMEOUT,
        open_timeout: OPEN_TIMEOUT
      )

      raise build_sync_error(response) unless response.success?

      data = JSON.parse(response.body)
      content = ""
      tool_calls = []

      data["content"].each do |part|
        case part["type"]
        when "text"
          content << part["text"]
        when "tool_use"
          tool_calls << {
            id: part["id"],
            type: "function",
            function: {
              name: part["name"],
              arguments: part["input"].to_json
            }
          }
        end
      end

      {
        content: content,
        tool_calls: tool_calls,
        tokens: data.dig("usage", "output_tokens") || estimate_tokens(content),
        finish_reason: data.dig("stop_reason") || "stop"
      }
    end

    def embeddings(text)
      # Anthropic doesn't have a native embeddings endpoint.
      # Use OpenAI-compatible embedding endpoint or a local model.
      raise NotImplementedError, "Use OpenAI or a local model for embeddings"
    end

    private

    def build_request_body(messages, tools, temperature, max_tokens, top_p = nil)
      system_message = messages.find { |m| m[:role] == "system" }
      chat_messages = messages.reject { |m| m[:role] == "system" }

      body = {
        model: model,
        messages: format_messages(chat_messages),
        temperature: temperature,
        max_tokens: max_tokens
      }
      body[:top_p] = top_p unless top_p.nil?
      body[:system] = system_message[:content] if system_message
      body[:tools] = format_tools(tools) if tools.any?

      body
    end

    def format_messages(messages)
      messages.map do |msg|
        { role: msg[:role], content: msg[:content].to_s }
      end
    end

    def format_tools(tools)
      tools.map do |tool|
        {
          name: tool[:name],
          description: tool[:description] || "",
          input_schema: tool[:parameters] || { type: "object", properties: {}, required: [] }
        }
      end
    end

    def headers
      {
        "x-api-key" => api_key,
        "anthropic-version" => "2024-02-01",
        "content-type" => "application/json"
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

    # A non-2xx streaming turn is an API failure, not an empty answer. Phrased
    # like sync_chat's error so the run records the status and the provider's
    # own complaint instead of finalizing a blank reply. Whitespace is collapsed:
    # a proxy's HTML failure would otherwise paint a multi-line blob into the
    # single-line error bubble.
    def stream_error(status, error_body, retry_after: nil)
      reason = error_body.to_s.gsub(/\s+/, " ").strip[0, MAX_ERROR_BODY]
      provider_type, provider_msg = extract_error_meta(error_body)
      Rails.logger.error "[shams] ERROR #{status} - #{(provider_msg.presence || reason).presence || "(empty body)"}"
      detail = reason.presence ? " - #{reason}" : " with no response body"
      code, retryable = classify(status, provider_type, provider_msg.presence || reason)
      LlmError.new("Anthropic API error: HTTP #{status}#{detail}",
        code: code, retryable: retryable, status: status,
        provider_error_type: provider_type, retry_after: retry_after)
    end

    # Build the typed error for a non-2xx non-streaming response. Keeps the
    # "<code> - <body>" phrasing the specs assert while attaching the cause.
    def build_sync_error(response)
      status = response.code.to_i
      provider_type, provider_msg = extract_error_meta(response.body)
      code, retryable = classify(status, provider_type, provider_msg)
      LlmError.new("Anthropic API error: #{response.code} - #{response.body}",
        code: code, retryable: retryable, status: status,
        provider_error_type: provider_type, retry_after: retry_after_seconds(response))
    end

    # Anthropic's error body is {"type":"error","error":{"type":..,"message":..}};
    # a proxy may return a flat {"error":..} or {"message":..}. Return
    # [error_type, error_message] using whichever shape is present.
    def extract_error_meta(body_str)
      parsed = (JSON.parse(body_str.to_s) rescue nil)
      return [ nil, nil ] unless parsed.is_a?(Hash)
      err = parsed["error"].is_a?(Hash) ? parsed["error"] : parsed
      [ err["type"].to_s.presence, (err["message"].to_s.presence || parsed["message"].to_s.presence) ]
    end

    # Turn (HTTP status, provider error.type, message) into [symbol_code,
    # retryable]. Precedence: the credit message sniff FIRST (a ceiling can arrive
    # as a 400, so status alone would misfile it), then the provider's structured
    # error.type, then the HTTP status, then a coarse status-class bucket, then
    # transport (retryable). Everything 4xx except 429 is permanent.
    def classify(status, provider_error_type, message)
      msg = message.to_s
      return [ :provider_credit_insufficient, false ] if msg.match?(CREDIT_MESSAGE_PATTERNS)
      return ERROR_TYPE_CODES[provider_error_type] if provider_error_type && ERROR_TYPE_CODES[provider_error_type]
      return STATUS_CODES[status] if status && STATUS_CODES[status]
      return [ :provider_unavailable, true ] if status && status >= 500
      return [ :provider_request_rejected, false ] if status && status >= 400
      [ :provider_unavailable, true ]
    end

    # A transport failure has no HTTP status at all. "Nothing is listening"
    # (refused / host unreachable / DNS) fails fast as :provider_unreachable; a
    # timeout is :provider_timeout; anything else is a generic transient
    # :provider_unavailable. These are retryable by default, but the streaming
    # wrapper forces retryable: false once content reached the consumer, since a
    # replay would duplicate what the user already saw.
    def provider_error(e, retryable: true)
      code =
        if connection_error?(e) then :provider_unreachable
        elsif timed_out?(e) then :provider_timeout
        else :provider_unavailable
        end
      LlmError.new("Anthropic request failed (#{e.class}): #{e.message.to_s[0, 200]}",
        code: code, retryable: retryable)
    end

    # Re-issue a retryable error as terminal: the code still names the cause, but
    # retryable? is flipped to false so no higher layer replays a turn that
    # already streamed content (which would duplicate the visible reply).
    def non_replayable(error)
      return error unless error.retryable?

      LlmError.new(error.message, code: error.code, retryable: false,
        status: error.status, provider_error_type: error.provider_error_type,
        retry_after: error.retry_after)
    end

    def connection_error?(e)
      CONNECTION_ERRORS.any? { |klass| e.is_a?(klass) }
    end

    def timed_out?(e)
      e.is_a?(Net::OpenTimeout) || e.is_a?(Net::ReadTimeout) || e.is_a?(Timeout::Error)
    end

    # Connection errors get the short fast-fail budget; genuine transients get the
    # full retry loop. Mirrors Llm::OpenaiAdapter so both providers behave alike.
    def retry_budget_for(e)
      connection_error?(e) ? (MAX_CONNECT_RETRIES + 1) : MAX_RETRIES
    end

    def backoff_for(e)
      connection_error?(e) ? CONNECT_BACKOFF : RETRY_BACKOFF
    end

    # Honour the provider's Retry-After on a rate limit, capped at RETRY_AFTER_MAX
    # so a long request never sleeps past our patience. A hint above the ceiling
    # is still respected at the ceiling (we do NOT fall back to fast retries, which
    # would only deepen a 429); with no usable hint we back off linearly.
    def retry_wait(e, attempt)
      hint = e.retry_after
      return [ hint, RETRY_AFTER_MAX ].min if hint&.positive?
      RETRY_BACKOFF * attempt
    end

    def retry_after_seconds(response)
      return nil unless response.respond_to?(:headers) && response.headers
      value = response.headers["retry-after"] || response.headers["Retry-After"]
      Integer(value.to_s.strip, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    # A provider failure carrying a machine-readable cause, not just prose.
    # `code` names WHY it failed (e.g. :provider_credit_insufficient), `retryable`
    # tells the caller whether redelivering the turn can ever help (transient
    # capacity/timeout vs a permanent bad key or empty credit), `status` and
    # `provider_error_type` preserve Anthropic's own signals for diagnostics, and
    # `retry_after` carries a rate-limit hint in seconds for the retry backoff.
    class LlmError < StandardError
      attr_reader :code, :status, :provider_error_type, :retry_after

      def initialize(message, code: :provider_unavailable, retryable: false,
                     status: nil, provider_error_type: nil, retry_after: nil)
        super(message)
        @code = code
        @retryable = retryable
        @status = status
        @provider_error_type = provider_error_type
        @retry_after = retry_after
      end

      def retryable?
        !!@retryable
      end
    end
  end
end
