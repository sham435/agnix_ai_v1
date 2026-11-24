# frozen_string_literal: true

module Llm
  class OpenaiAdapter
    BASE_URL = "https://api.openai.com/v1"
    SUCCESS_STATUSES = (200..299).freeze
    MAX_ERROR_BODY = 8.kilobytes
    MAX_TOOL_CALLS = 128
    MAX_TOOL_INDEX = 10_000
    PROTECTED_PARAMETERS = %w[model messages input tools tool_choice stream].freeze
    LlmError = ProviderError

    attr_reader :api_key, :model, :base_url, :top_p, :chat_template_kwargs, :connection

    def initialize(api_key:, model:, base_url: nil, top_p: nil, chat_template_kwargs: nil, connection: nil)
      @api_key = api_key
      @model = model
      @top_p = top_p
      @chat_template_kwargs = chat_template_kwargs
      @connection = connection || ProviderConnection.new(
        provider: inferred_provider(base_url, api_key, chat_template_kwargs), api_key: api_key, model: model, base_url: base_url
      )
      @base_url = @connection.base_url
    end

    def chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, stream: false, &block)
      Rails.logger.info "[shams] chat model=#{model} tools=#{tools.present?} stream=#{stream}"
      if stream
        stream_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p, &block)
      else
        sync_chat(messages: messages, tools: tools, temperature: temperature, max_tokens: max_tokens, top_p: top_p)
      end
    end

    def stream_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, &block)
      raise ProviderError.new("Streaming is not enabled for this model.", code: "configuration_invalid") unless parameter_allowed?("stream")

      body = build_request_body(messages, tools, temperature, max_tokens, top_p)
      body[:stream] = true
      body[:stream_options] = { include_usage: true } if parameter_allowed?("stream_options")
      state = { content: +"", reasoning: +"", tool_calls: {}, tokens: nil, finish_reason: nil, done: false }
      buffer = +""
      attempt = 0

      begin
        attempt += 1
        state = { content: +"", reasoning: +"", tool_calls: {}, tokens: nil, finish_reason: nil, done: false }
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
          lines.each { |line| consume_line(line, state, &block) }
        end
        stream_status ||= status_of(response)
        stream_retry_after ||= ProviderError.retry_after_seconds(response_headers(response))
        if stream_status && !SUCCESS_STATUSES.cover?(stream_status)
          raise ProviderError.from_http(stream_status, error_body, request_id: request_id_from(response),
            retry_after: stream_retry_after)
        end
        consume_line(buffer, state, &block) unless buffer.empty?
        unless state[:done]
          raise ProviderError.new(ProviderError::MESSAGES["provider_stream_interrupted"],
            code: "provider_stream_interrupted", retryable: state[:content].empty? && state[:reasoning].empty?)
        end
      rescue ProviderError => error
        raise unless error.retryable? && state[:content].empty? && attempt < retry_limit(error)

        Rails.logger.warn "[shams] stream retry #{attempt} after #{error.code}"
        sleep(retry_delay(error, attempt))
        retry
      end

      { content: state[:content], tool_calls: ordered_tool_calls(state),
        tokens: state[:tokens] || estimate_tokens(state[:content]), finish_reason: state[:finish_reason] || "stop" }
    end

    def sync_chat(messages:, tools:, temperature:, max_tokens:, top_p: nil, **)
      response = sync_chat_with_retry(build_request_body(messages, tools, temperature, max_tokens, top_p))
      data = parse_json(response.body)
      choices = data["choices"]
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless choices.is_a?(Array) && choices.first.is_a?(Hash)

      choice = choices.first
      if choice["error"]
        unless choice["error"].is_a?(Hash)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end

        status = choice["error"]["status"]
        raise ProviderError.from_http(status.to_i, choice.to_json) if status.is_a?(Numeric)

        metadata = ProviderError.error_metadata(choice)
        code = ProviderError::TYPE_CODES[metadata[:type]] || ProviderError::TYPE_CODES[metadata[:code]] || "provider_error"
        raise ProviderError.new(ProviderError::MESSAGES.fetch(code, "The provider request failed."), code: code,
          provider_error_type: metadata[:type], provider_error_code: metadata[:code])
      end

      message = choice["message"]
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless message.is_a?(Hash)
      unless message["tool_calls"].nil? || message["tool_calls"].is_a?(Array)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      calls = Array(message["tool_calls"])
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") if calls.length > MAX_TOOL_CALLS

      tool_calls = calls.map do |tool_call|
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless tool_call.is_a?(Hash)

        function = tool_call["function"]
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response") unless function.is_a?(Hash)

        { id: tool_call["id"].presence || SecureRandom.hex(16), type: "function",
          function: normalize_function(function["name"], function["arguments"]) }
      end
      content = message["content"]
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless content.nil? || content.is_a?(String)
      { content: content.to_s, tool_calls: tool_calls,
        tokens: data.dig("usage", "completion_tokens") || estimate_tokens(content),
        finish_reason: choice["finish_reason"] || (tool_calls.any? ? "tool_calls" : "stop") }
    end

    def embeddings(text)
      response = sync_chat_with_retry({ model: "text-embedding-3-small", input: text, encoding_format: "float" }, path: "embeddings")
      data = parse_json(response.body).dig("data", 0, "embedding")
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless data.is_a?(Array)

      data
    end

    private

    def stream_tool_index(value, fallback)
      index = if value.nil?
                fallback
      elsif value.is_a?(Integer)
                value
      else
                Integer(value.to_s, 10)
      end
      unless index.between?(0, MAX_TOOL_INDEX)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end

      index
    rescue ArgumentError, TypeError
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response")
    end

    def ordered_tool_calls(state, validate: true)
      state[:tool_calls].keys.sort.map do |index|
        call = state[:tool_calls][index]
        function = call[:function] || call["function"] || {}
        name = function[:name] || function["name"]
        arguments = function[:arguments] || function["arguments"]
        normalized = validate ? normalize_function(name, arguments) : { "name" => name, "arguments" => arguments }
        { id: (call[:id] || call["id"]).presence || SecureRandom.hex(16), type: "function",
          function: normalized }
      end
    end

    def normalize_function(name, arguments)
      valid_name = name.is_a?(String) && name.bytesize.between?(1, 256) && name.match?(/\A[A-Za-z0-9_.-]+\z/)
      valid_arguments = arguments.is_a?(String) && arguments.bytesize <= 1.megabyte
      unless valid_name && valid_arguments
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"], code: "invalid_provider_response")
      end

      { "name" => name, "arguments" => arguments }
    end

    def inferred_provider(base_url, key, template)
      return "bonsai" if template
      return "bonsai" if base_url.to_s.match?(%r{\Ahttp://(?:127\.0\.0\.1|localhost|\[::1\]):(?:8080|8910)/})
      return "ollama" if base_url.to_s.match?(%r{\Ahttp://(?:127\.0\.0\.1|localhost|\[::1\])})
      return "openrouter" if base_url.to_s.include?("openrouter.ai") || key.to_s.start_with?("sk-or-v1")

      "openai"
    end

    def request_path
      "chat/completions"
    end

    def retry_limit(error)
      error.connection_error? ? 2 : connection.max_retries + 1
    end

    def consume_line(line, state, &block)
      line = line.chomp
      return unless line.start_with?("data:")

      data = line.delete_prefix("data:").strip
      return if data.empty?
      if data == "[DONE]"
        state[:done] = true
        return
      end

      event = JSON.parse(data)
      if !event.is_a?(Hash)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      if event["error"]
        error = event["error"]
        unless error.is_a?(Hash)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end

        metadata = ProviderError.error_metadata(event)
        status = error["status"]
        raise ProviderError.from_http(status.to_i, event.to_json) if status.is_a?(Numeric)

        code = ProviderError::TYPE_CODES[metadata[:type]] || ProviderError::TYPE_CODES[metadata[:code]] || "provider_error"
        raise ProviderError.new(ProviderError::MESSAGES.fetch(code, "The provider request failed."), code: code,
          retryable: code == "provider_rate_limited", provider_error_type: metadata[:type], provider_error_code: metadata[:code])
      end

      usage_tokens = event.dig("usage", "completion_tokens") if event["usage"]
      state[:tokens] = usage_tokens if usage_tokens
      choice = event.dig("choices", 0)
      return unless choice

      state[:finish_reason] = choice["finish_reason"] if choice["finish_reason"]
      delta = choice["delta"] || {}
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response") unless delta.is_a?(Hash)

      %w[reasoning_content reasoning content].each do |name|
        next if delta[name].nil? || delta[name].is_a?(String)

        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"], code: "invalid_provider_response")
      end
      thought = delta["reasoning_content"].presence || delta["reasoning"].presence
      if thought
        state[:reasoning] << thought
        block.call(thought, state[:reasoning], ordered_tool_calls(state, validate: false), "reasoning") if block
      end
      if delta["content"]
        state[:content] << delta["content"]
        block.call(delta["content"], state[:content], ordered_tool_calls(state, validate: false), "content") if block
      end
      calls = delta["tool_calls"]
      unless calls.nil? || (calls.is_a?(Array) && calls.length <= MAX_TOOL_CALLS)
        raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
          code: "invalid_provider_response")
      end
      Array(calls).each do |tool_call|
        unless tool_call.is_a?(Hash) && (tool_call["function"].nil? || tool_call["function"].is_a?(Hash))
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        index = stream_tool_index(tool_call["index"], state[:tool_calls].length)
        if !state[:tool_calls].key?(index) && state[:tool_calls].length >= MAX_TOOL_CALLS
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        current = state[:tool_calls][index] ||= { id: nil, type: "function",
          function: { name: nil, arguments: +"" } }
        current[:id] = tool_call["id"] if tool_call["id"].present?
        function = tool_call["function"] || {}
        if function["name"].present? && !function["name"].is_a?(String)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        current[:function][:name] = function["name"] if function["name"].present?
        arguments = function["arguments"]
        unless arguments.nil? || arguments.is_a?(String)
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
            code: "invalid_provider_response")
        end
        current[:function][:arguments] << arguments.to_s
      end
    rescue JSON::ParserError
      raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"],
        code: "invalid_provider_response")
    end

    def sync_chat_with_retry(body, path: request_path)
      attempt = 0
      begin
        attempt += 1
        response = SecureHttp.post(connection, path, body: body)
        status = status_of(response) || (response.success? ? 200 : 502)
        raise ProviderError.from_http(status, response.body, request_id: request_id_from(response),
          headers: response_headers(response)) unless SUCCESS_STATUSES.cover?(status)

        response
      rescue ProviderError => error
        raise unless error.retryable? && attempt < retry_limit(error)

        Rails.logger.warn "[shams] request retry #{attempt} after #{error.code}"
        sleep(retry_delay(error, attempt))
        retry
      end
    end

    def build_request_body(messages, tools, temperature, max_tokens, top_p = nil)
      body = connection.options.except(*PROTECTED_PARAMETERS).dup
      body["model"] = model
      body["messages"] = messages.map { |message| format_message(message) }
      body["temperature"] = temperature
      body["max_tokens"] = capped_tokens(max_tokens)
      body["top_p"] = top_p unless top_p.nil?
      if tools.any? && !parameter_allowed?("tools")
        raise ProviderError.new(ProviderError::MESSAGES["provider_tool_incompatible"],
          code: "provider_tool_incompatible")
      end
      if !connection.model_config["supports_parallel_tool_calls"].nil? && connection.model_config["supports_parallel_tool_calls"] == false
        body["parallel_tool_calls"] = false
      end
      body["chat_template_kwargs"] = chat_template_kwargs if chat_template_kwargs
      if tools.any?
        body["tools"] = tools.map do |tool|
          { type: "function", function: { name: tool[:name], description: tool[:description] || "",
                                           parameters: tool[:parameters] || { type: "object", properties: {}, required: [] } } }
        end
      end
      body.reject { |name, _value| !parameter_allowed?(name) }.transform_keys(&:to_sym)
    end

    def capped_tokens(value)
      limit = connection.model_config["max_output_tokens"]
      limit.is_a?(Integer) && limit.positive? ? [ value.to_i, limit ].min : value
    end

    def parameter_allowed?(name)
      connection.parameter_allowed?(name)
    end

    def retry_delay(error, attempt)
      error.retry_after || (error.connection_error? ? 0.5 * attempt : 2 * attempt)
    end

    def response_headers(response)
      response.headers if response.respond_to?(:headers)
    end

    def request_id_from(response)
      return unless response.respond_to?(:headers) && response.headers.respond_to?(:[])

      response.headers["x-request-id"].presence
    end

    def format_message(message)
      formatted = { role: message[:role], content: message[:content] }
      if message[:role] == "tool"
        formatted[:tool_call_id] = message[:tool_call_id]
      elsif message[:role] == "assistant" && (message[:tool_calls] || message[:tool_call_id])
        formatted[:tool_calls] = message[:tool_calls]
      end
      formatted
    end

    def parse_json(body)
      data = JSON.parse(body.to_s)
      raise ProviderError.new("The provider returned an invalid response.", code: "invalid_provider_response") unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise ProviderError.new("The provider returned an invalid response.", code: "invalid_provider_response")
    end

    def status_of(source)
      return nil unless source.respond_to?(:code)

      Integer(source.code.to_s, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end
  end
end
