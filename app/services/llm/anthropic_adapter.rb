# frozen_string_literal: true

# Anthropic Claude API adapter.
# API docs: https://docs.anthropic.com/en/api/messages
module Llm
  class AnthropicAdapter
    # A streaming turn is judged by its status line, not by what the body happens
    # to parse into: only 2xx is a response, anything else is a gateway or API
    # failure. Error bodies are retained only for bounded classification and are
    # never copied into user-facing errors or logs.
    SUCCESS_STATUSES = (200..299).freeze

    # Retaining a bounded JSON prefix keeps an out-of-credit 400 from being
    # misfiled as a generic rejection just because its message was long.
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
    TRANSPORT_ERROR_CODES = %i[
      endpoint_invalid endpoint_forbidden request_too_large response_too_large
      invalid_provider_response configuration_invalid
    ].freeze
    ERROR_MESSAGES = {
      "provider_permission_denied" => ProviderError::MESSAGES["provider_access_restricted"],
      "provider_overloaded" => ProviderError::MESSAGES["provider_unavailable"],
      "provider_unreachable" => ProviderError::MESSAGES["provider_network_error"]
    }.freeze

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

    attr_reader :api_key, :model, :connection

    def initialize(api_key:, model:, connection: nil)
      @connection = connection || ProviderConnection.new(provider: "anthropic", api_key: api_key, model: model)
      @api_key = @connection.api_key
      @model = model
    end

    def chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, stream: false, &block)
      if stream
        # The block only means something on the streaming path: stream_chat yields
        # deltas as they arrive, while sync_chat returns one finished response.
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p, &block)
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
        if e.retryable? && !streamed_any && attempt < retry_budget_for(e)
          Rails.logger.warn "[shams] anthropic stream retry #{attempt}/#{retry_budget_for(e)} after #{e.code}"
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

      response = post(body) do |chunk|
        # HTTParty yields a ResponseFragment while streaming, which answers
        # #code as soon as the headers arrive. A rejection is not an SSE stream
        # - Anthropic answers 4xx/5xx with one JSON object, a proxy may answer
        # with HTML - so keep the reason, skip the parse, and fail below instead
        # of finalizing the turn as an empty reply.
        status = status_of(chunk)
        if status
          stream_status = status
          unless SUCCESS_STATUSES.cover?(status)
            remaining = ERROR_CLASSIFY_LIMIT - error_body.bytesize
            error_body << chunk.to_s.byteslice(0, remaining) if remaining.positive?
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

        # A rejected request also arrives as one JSON object, not a message.
        # Classify its bounded metadata but never expose the provider's body.
        if parsed.is_a?(Hash) && parsed["type"] == "error"
          err = parsed["error"].is_a?(Hash) ? parsed["error"] : {}
          message = err["message"].to_s.byteslice(0, ERROR_CLASSIFY_LIMIT).scrub
          code, retryable = classify(nil, err["type"], message)
          raise LlmError.new("Anthropic API error. #{safe_error_message(code)}",
            code: code, retryable: retryable,
            provider_error_type: err["type"].to_s.byteslice(0, 256).scrub.presence)
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
        if e.retryable? && attempt < retry_budget_for(e)
          Rails.logger.warn "[shams] anthropic sync retry #{attempt}/#{retry_budget_for(e)} after #{e.code}"
          sleep(retry_wait(e, attempt))
          retry
        end
        raise e
      end
    end

    # One non-streaming request. Raises a typed LlmError for a rejection so
    # sync_chat can decide whether the failure is worth replaying.
    def do_sync_chat(body)
      response = post(body)

      raise build_sync_error(response) unless response.success?

      data = JSON.parse(response.body)
      raise invalid_sync_response(response) unless data.is_a?(Hash) && data["content"].is_a?(Array)

      content = +""
      tool_calls = []

      data["content"].each do |part|
        raise invalid_sync_response(response) unless part.is_a?(Hash)

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
    rescue JSON::ParserError, TypeError
      raise invalid_sync_response(response)
    end

    def embeddings(text)
      # Anthropic doesn't have a native embeddings endpoint.
      # Use OpenAI-compatible embedding endpoint or a local model.
      raise NotImplementedError, "Use OpenAI or a local model for embeddings"
    end

    private

    def post(body, &block)
      SecureHttp.post(connection, "messages", body: body, headers: headers, &block)
    rescue ProviderError => error
      raise if error.is_a?(LlmError)

      raise provider_error(error)
    end

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
      connection.headers.merge("anthropic-version" => ENV.fetch("ANTHROPIC_API_VERSION", "2023-06-01"))
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

    # A non-2xx turn is an API failure, not an empty answer. The bounded body is
    # used only to classify the failure; logs and user-facing errors stay redacted.
    def stream_error(status, error_body, retry_after: nil)
      error_body = error_body.scrub
      provider_type, provider_msg = extract_error_meta(error_body)
      code, retryable = classify(status, provider_type, provider_msg.presence || error_body)
      Rails.logger.error "[shams] anthropic request failed with HTTP #{status} (#{code})"
      LlmError.new("Anthropic API error: HTTP #{status}. #{safe_error_message(code)}",
        code: code, retryable: retryable, status: status,
        provider_error_type: provider_type, retry_after: retry_after)
    end

    def build_sync_error(response)
      status = response.code.to_i
      provider_type, provider_msg = extract_error_meta(response.body)
      code, retryable = classify(status, provider_type, provider_msg)
      LlmError.new("Anthropic API error: HTTP #{status}. #{safe_error_message(code)}",
        code: code, retryable: retryable, status: status,
        provider_error_type: provider_type, retry_after: retry_after_seconds(response))
    end

    def invalid_sync_response(response)
      LlmError.new("Anthropic API error. #{safe_error_message(:invalid_provider_response)}",
        code: :invalid_provider_response, retryable: false, status: response.code.to_i)
    end

    def safe_error_message(code)
      key = code.to_s
      message = ERROR_MESSAGES[key] || ProviderError::MESSAGES[key]
      return message if message
      return "The model request exceeds the configured size limit." if code == :request_too_large

      "The provider request failed."
    end

    # Anthropic's error body is {"type":"error","error":{"type":..,"message":..}};
    # a proxy may return a flat {"error":..} or {"message":..}. Return
    # [error_type, error_message] using whichever shape is present.
    def extract_error_meta(body_str)
      parsed = (JSON.parse(body_str.to_s.scrub) rescue nil)
      return [ nil, nil ] unless parsed.is_a?(Hash)
      err = parsed["error"].is_a?(Hash) ? parsed["error"] : parsed
      type = err["type"].to_s.byteslice(0, 256).scrub.presence
      message = (err["message"].to_s.presence || parsed["message"].to_s.presence)
      [ type, message&.byteslice(0, ERROR_CLASSIFY_LIMIT)&.scrub ]
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
    def provider_error(error, retryable: nil)
      cause = error.respond_to?(:cause_error) ? error.cause_error : nil
      failure = cause || error
      provider_code = error.code.to_s.to_sym if error.respond_to?(:code)
      code = if TRANSPORT_ERROR_CODES.include?(provider_code)
               provider_code
      elsif connection_error?(failure)
               :provider_unreachable
      elsif timed_out?(failure) || provider_code == :provider_timeout
               :provider_timeout
      else
               :provider_unavailable
      end
      message = safe_error_message(code)
      message = "#{message} (#{failure.class})" if cause
      retryable = error.respond_to?(:retryable?) ? error.retryable? : true if retryable.nil?
      LlmError.new(message, code: code, retryable: retryable,
        status: error.respond_to?(:status) ? error.status : nil,
        provider_error_type: error.respond_to?(:provider_error_type) ? error.provider_error_type : nil,
        provider_error_code: error.respond_to?(:provider_error_code) ? error.provider_error_code : nil,
        request_id: error.respond_to?(:request_id) ? error.request_id : nil,
        retry_after: error.respond_to?(:retry_after) ? error.retry_after : nil, cause_error: cause)
    end

    # Re-issue a retryable error as terminal: the code still names the cause, but
    # retryable? is flipped to false so no higher layer replays a turn that
    # already streamed content (which would duplicate the visible reply).
    def non_replayable(error)
      return error unless error.retryable?

      LlmError.new(error.message, code: error.code, retryable: false,
        status: error.status, provider_error_type: error.provider_error_type,
        provider_error_code: error.provider_error_code, request_id: error.request_id,
        retry_after: error.retry_after, cause_error: error.cause_error)
    end

    def connection_error?(e)
      CONNECTION_ERRORS.any? { |klass| e.is_a?(klass) }
    end

    def timed_out?(e)
      e.is_a?(Net::OpenTimeout) || e.is_a?(Net::ReadTimeout) || e.is_a?(Timeout::Error)
    end

    # Connection errors get the short fast-fail budget; genuine transients get the
    # full retry loop. Mirrors Llm::OpenaiAdapter so both providers behave alike.
    def retry_budget_for(error)
      connection_error?(underlying_error(error)) ? (MAX_CONNECT_RETRIES + 1) : MAX_RETRIES
    end

    def backoff_for(error)
      connection_error?(underlying_error(error)) ? CONNECT_BACKOFF : RETRY_BACKOFF
    end

    def underlying_error(error)
      error.respond_to?(:cause_error) ? error.cause_error || error : error
    end

    # Honour the provider's Retry-After on a rate limit, capped at RETRY_AFTER_MAX
    # so a long request never sleeps past our patience. A hint above the ceiling
    # is still respected at the ceiling (we do NOT fall back to fast retries, which
    # would only deepen a 429); with no usable hint we back off linearly.
    def retry_wait(e, attempt)
      hint = e.retry_after
      return [ hint, RETRY_AFTER_MAX ].min if hint&.positive?

      backoff_for(e) * attempt
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
    class LlmError < ProviderError
      attr_reader :code

      def initialize(message, code: :provider_unavailable, retryable: false,
                     status: nil, provider_error_type: nil, provider_error_code: nil,
                     request_id: nil, retry_after: nil, cause_error: nil)
        super(message, code: code, retryable: retryable, status: status,
          provider_error_type: provider_error_type, provider_error_code: provider_error_code,
          request_id: request_id, retry_after: retry_after)
        @code = code
        @cause_error = cause_error if cause_error
      end

      def retryable?
        !!@retryable
      end
    end
  end
end
