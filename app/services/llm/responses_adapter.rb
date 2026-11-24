# frozen_string_literal: true

module Llm
  class ResponsesAdapter < OpenaiAdapter
    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      response = sync_chat_with_retry(build_request_body(messages, tools, temperature, max_tokens, top_p))
      data = parse_json(response.body)
      normalize_response(data)
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, &block)
      raise ProviderError.new("Streaming is not enabled for this model.", code: "configuration_invalid") unless parameter_allowed?("stream")

      body = build_request_body(messages, tools, temperature, max_tokens, top_p)
      body[:stream] = true
      state = { content: +"", reasoning: +"", tool_calls: {}, tokens: nil, finish_reason: nil, items: {}, tool_slots: {} }
      buffer = +""
      attempt = 0
      terminal_event = false
      begin
        attempt += 1
        terminal_event = false
        state = { content: +"", reasoning: +"", tool_calls: {}, tokens: nil, finish_reason: nil, items: {}, tool_slots: {} }
        buffer = +""
        stream_status = nil
        stream_retry_after = nil
        error_body = +""
        response = SecureHttp.post(connection, request_path, body: body) do |chunk|
          status = status_of(chunk)
          if status
            stream_status = status
            stream_retry_after ||= ProviderError.retry_after_seconds(chunk.headers) if chunk.respond_to?(:headers)
            unless SUCCESS_STATUSES.cover?(status)
              error_body << chunk.to_s if error_body.bytesize < MAX_ERROR_BODY
              next
            end
          end
          text = buffer + chunk.to_s
          lines = text.lines
          buffer = lines.pop.to_s unless text.end_with?("\n")
          lines.each do |line|
            terminal_event = true if consume_line(line, state, &block)
          end
        end
        stream_status ||= status_of(response)
        stream_retry_after ||= ProviderError.retry_after_seconds(response_headers(response))
        if stream_status && !SUCCESS_STATUSES.cover?(stream_status)
          raise ProviderError.from_http(stream_status, error_body, request_id: request_id_from(response),
            retry_after: stream_retry_after)
        end

        terminal_event = true if consume_line(buffer, state, &block) unless buffer.empty?
        unless terminal_event
          raise ProviderError.new(ProviderError::MESSAGES["provider_stream_interrupted"],
            code: "provider_stream_interrupted", retryable: state[:content].empty? && state[:reasoning].empty?)
        end
      rescue ProviderError => error
        raise unless error.retryable? && state[:content].empty? && attempt < retry_limit(error)

        Rails.logger.warn "[shams] responses stream retry #{attempt} after #{error.code}"
        sleep(retry_delay(error, attempt))
        retry
      end
      { content: state[:content], tool_calls: ordered_tool_calls(state),
        tokens: state[:tokens] || estimate_tokens(state[:content]), finish_reason: state[:finish_reason] || "stop" }
    end

    private

    def request_path
      "responses"
    end

    def build_request_body(messages, tools, temperature, max_tokens, top_p = nil)
      body = connection.options.except(*PROTECTED_PARAMETERS).dup
      body["model"] = model
      body["input"] = messages.flat_map { |message| format_response_message(message) }
      body["temperature"] = temperature
      body["max_output_tokens"] = capped_tokens(max_tokens)
      body["top_p"] = top_p unless top_p.nil?
      if tools.any? && !parameter_allowed?("tools")
        raise ProviderError.new(ProviderError::MESSAGES["provider_tool_incompatible"],
          code: "provider_tool_incompatible")
      end
      if !connection.model_config["supports_parallel_tool_calls"].nil? && connection.model_config["supports_parallel_tool_calls"] == false
        body["parallel_tool_calls"] = false
      end
      if tools.any?
        body["tools"] = tools.map do |tool|
          { type: "function", name: tool[:name], description: tool[:description] || "",
            parameters: tool[:parameters] || { type: "object", properties: {}, required: [] } }
        end
      end
      body.reject { |name, _value| !parameter_allowed?(name) }.transform_keys(&:to_sym)
    end

    def format_response_message(message)
      role = message[:role].to_s
      if role == "tool"
        return [ { type: "function_call_output", call_id: message[:tool_call_id], output: message[:content] } ]
      end
      result = [ { role: role, content: message[:content] } ]
      Array(message[:tool_calls]).each do |tool_call|
        function = tool_call[:function] || tool_call["function"] || {}
        normalized = normalize_function(function[:name] || function["name"], function[:arguments] || function["arguments"])
        result << { type: "function_call", call_id: tool_call[:id] || tool_call["id"],
                    name: normalized["name"], arguments: normalized["arguments"] }
      end
      result
    end

    def normalize_response(data)
      normalize_failed_response(data) if data["status"] == "failed"
      output = data["output"]
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless output.is_a?(Array)

      if data["status"] == "incomplete" && data.dig("incomplete_details", "reason") == "content_filter"
        raise ProviderError.new(ProviderError::MESSAGES["provider_access_restricted"], code: "provider_access_restricted")
      end
      content = +""
      function_calls = output.select { |item| item.is_a?(Hash) && item["type"] == "function_call" }
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") if function_calls.length > MAX_TOOL_CALLS

      tool_calls = function_calls.map { |item| normalize_response_tool_call(item) }
      output.each do |item|
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless item.is_a?(Hash)
        next unless item["type"] == "message"

        parts = item["content"]
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless parts.is_a?(Array)

        parts.each do |part|
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response") unless part.is_a?(Hash)
          next unless part["type"] == "output_text"

          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response") unless part["text"].is_a?(String)

          content << part["text"]
        end
      end
      if content.strip.empty? && tool_calls.empty?
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      finish_reason = if data["status"] == "incomplete"
                        data.dig("incomplete_details", "reason") == "max_output_tokens" ? "length" : "stop"
      else
                        tool_calls.any? ? "tool_calls" : "stop"
      end
      { content: content, tool_calls: tool_calls, tokens: data.dig("usage", "output_tokens") || estimate_tokens(content),
        finish_reason: finish_reason }
    end

    def normalize_response_tool_call(item)
      { id: item["call_id"].presence || item["id"], type: "function",
        function: normalize_function(item["name"], item["arguments"]) }
    end

    def consume_line(line, state, &block)
      line = line.chomp
      return unless line.start_with?("data:")

      data = line.delete_prefix("data:").strip
      return if data.empty? || data == "[DONE]"

      event = JSON.parse(data)
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless event.is_a?(Hash)
      if event["error"]
        error = event["error"]
        unless error.is_a?(Hash)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end

        status = error["status"]
        raise ProviderError.from_http(status.to_i, event.to_json) if status.is_a?(Numeric)

        metadata = ProviderError.error_metadata(event)
        code = ProviderError::TYPE_CODES[metadata[:type]] || ProviderError::TYPE_CODES[metadata[:code]] || "provider_error"
        raise ProviderError.new(ProviderError::MESSAGES.fetch(code, "The provider request failed."), code: code,
          retryable: code == "provider_rate_limited", provider_error_type: metadata[:type], provider_error_code: metadata[:code])
      end

      case event["type"]
      when "response.output_text.delta"
        delta = event["delta"]
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless delta.is_a?(String)
        state[:content] << delta
        block.call(delta, state[:content], ordered_tool_calls(state, validate: false), "content") if block && delta.present?
      when "response.reasoning_summary_text.delta"
        delta = event["delta"]
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless delta.is_a?(String)
        state[:reasoning] << delta
        block.call(delta, state[:reasoning], ordered_tool_calls(state, validate: false), "reasoning") if block && delta.present?
      when "response.output_item.added"
        remember_response_item(event["item"], event["output_index"], state)
      when "response.function_call_arguments.delta"
        unless event["delta"].is_a?(String)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        item = response_item(event["item_id"], event["output_index"], state)
        item[:function][:arguments] << event["delta"]
      when "response.output_item.done"
        remember_response_item(event["item"], event["output_index"], state, complete: true)
      when "response.completed"
        response = event["response"].is_a?(Hash) ? event["response"] : {}
        state[:tokens] = response.dig("usage", "output_tokens")
        output = response["output"]
        unless output.nil? || (output.is_a?(Array) && output.all? { |item| item.is_a?(Hash) })
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        function_calls = Array(output).select { |item| item["type"] == "function_call" }
        if function_calls.length > MAX_TOOL_CALLS
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        state[:tool_calls] = {}
        function_calls.each_with_index do |item, index|
          state[:tool_calls][index] = normalize_response_tool_call(item)
        end
        state[:finish_reason] = response["status"] == "incomplete" ? "length" : (state[:tool_calls].any? ? "tool_calls" : "stop")
      when "response.incomplete"
        response = event["response"].is_a?(Hash) ? event["response"] : {}
        state[:finish_reason] = response.dig("incomplete_details", "reason") == "max_output_tokens" ? "length" : "stop"
      when "response.failed"
        normalize_failed_response(event["response"] || {})
      end
      true if %w[response.completed response.incomplete].include?(event["type"])
    rescue JSON::ParserError
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response")
    end

    def normalize_failed_response(response)
      unless response.is_a?(Hash)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end

      error = response["error"]
      if error.present? && !error.is_a?(Hash)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end

      status = error.is_a?(Hash) ? error["status"] : nil
      raise ProviderError.from_http(status.to_i, response.to_json) if status.is_a?(Numeric)

      metadata = ProviderError.error_metadata(response)
      code = ProviderError::TYPE_CODES[metadata[:type]] || ProviderError::TYPE_CODES[metadata[:code]] || "provider_unavailable"
      raise ProviderError.new(ProviderError::MESSAGES.fetch(code), code: code,
        retryable: %w[provider_unavailable provider_rate_limited provider_timeout].include?(code),
        provider_error_type: metadata[:type], provider_error_code: metadata[:code])
    end

    def response_item(id, index, state)
      validated_index = stream_tool_index(index, nil) unless index.nil?
      key = id || validated_index || state[:items].length
      unless state[:items].key?(key) || state[:items].length < MAX_TOOL_CALLS
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"], code: "invalid_provider_response")
      end
      state[:items][key] ||= { id: id, type: "function",
                               function: { name: nil, arguments: +"" } }
    end

    def remember_response_item(item, index, state, complete: false)
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless item.is_a?(Hash)
      return unless item["type"] == "function_call"

      validated_index = stream_tool_index(index, nil) unless index.nil?
      key = item["id"] || validated_index
      current = response_item(item["id"], index, state)
      current[:id] = item["call_id"].presence || item["id"] if item["call_id"].present? || item["id"].present?
      if item["name"].present? && !item["name"].is_a?(String)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      current[:function][:name] = item["name"] if item["name"].present?
      if complete && !item["arguments"].nil? && !item["arguments"].is_a?(String)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      current[:function][:arguments] = item["arguments"] if complete && item["arguments"].is_a?(String)
      slot = state[:tool_slots][key]
      unless slot
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") if state[:tool_calls].length >= MAX_TOOL_CALLS

        slot = validated_index || next_tool_slot(state)
        state[:tool_slots][key] = slot
      end
      state[:tool_calls][slot] = current
    end

    def next_tool_slot(state)
      slot = Array(state[:tool_calls].keys).max.to_i + 1
      stream_tool_index(slot, nil)
    end
  end
end
