# frozen_string_literal: true

module Llm
  class ProviderConnection
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 120
    DEFAULT_MAX_REQUEST_BYTES = 8.megabytes
    DEFAULT_MAX_RESPONSE_BYTES = 2.megabytes
    DEFAULT_MAX_STREAM_BYTES = 16.megabytes
    VERSION_SEGMENT = /\Av\d+(?:beta\d*|alpha\d*)?\z/i
    OPERATION_SUFFIXES = [ %w[chat completions], %w[responses], %w[embeddings], %w[models] ].freeze

    attr_reader :provider, :integration, :api_key, :model, :base_url, :config

    def initialize(provider:, integration: nil, api_key: nil, model: nil, base_url: nil, model_config: nil)
      @integration = integration
      @model = model.to_s
      @model_config_override = model_config.is_a?(Hash) ? model_config : nil
      @pinned_addresses = {}
      @config = integration&.config.to_h || {}
      @api_key = (api_key || integration&.api_key).to_s.strip.presence
      @provider = self.class.resolve_provider(provider, @api_key)
      configured_url = (base_url || configured_base_url).to_s.strip
      @base_url = @provider == "bonsai" ? configured_url.sub(%r{/+\z}, "") : normalize_base_url(configured_url)
      validate!
    end

    def self.resolve_provider(provider, api_key)
      return "openrouter" if provider.to_s == "openai" && api_key.to_s.start_with?("sk-or-v1")

      provider.to_s
    end

    def self.resolve(organization:, provider:, model: nil, api_key: nil)
      requested_provider = provider.to_s
      stored = organization.tool_integrations.find_by(provider: requested_provider)
      if stored && !stored.is_active? && api_key.blank?
        return new(provider: requested_provider, model: model)
      end

      integration = stored if stored&.is_active?
      server_credentials_allowed = ProviderRegistry.definition(requested_provider)[:local] ||
        authorized_system_fallback?(organization, requested_provider, model)
      key = api_key.presence || integration&.api_key.presence ||
        (ProviderRegistry.environment_key(requested_provider) if server_credentials_allowed) ||
        (ProviderRegistry.credentials_key(requested_provider) if server_credentials_allowed) ||
        (ENV["OPENROUTER_API_KEY"].to_s.strip.presence if server_credentials_allowed && requested_provider == "openai") ||
        ProviderRegistry.default_api_key(requested_provider)
      new(provider: requested_provider, integration: integration, api_key: key, model: model)
    end

    def self.authorized_system_fallback?(organization, provider, model)
      organization.settings["allow_system_model_fallback"] == true &&
        provider == ENV["SHAMS_DEFAULT_MODEL_PROVIDER"].to_s.strip.presence &&
        model.to_s == ENV["SHAMS_DEFAULT_MODEL_ID"].to_s.strip.presence
    end
    private_class_method :authorized_system_fallback?

    def custom?
      ProviderRegistry.custom?(provider)
    end

    def model_config
      return @model_config_override if @model_config_override

      models = config.fetch("models", {})
      models.is_a?(Hash) ? models.fetch(model, {}) : {}
    end

    def api_family
      model_config["api_family"].presence || ProviderRegistry.default_api_family(provider)
    end

    def supported_parameters
      configured = model_config["supported_parameters"]
      return ProviderRegistry.supported_parameters(provider, api_family) unless configured.is_a?(Array)

      ProviderRegistry.supported_parameters(provider, api_family) & configured.map(&:to_s)
    end

    def parameter_allowed?(name)
      name = name.to_s
      return false if name == "stream" && supports?("supports_streaming") == false
      return false if supports?("supports_tools") == false && %w[tools tool_choice parallel_tool_calls].include?(name)

      %w[model messages input stream chat_template_kwargs].include?(name) || supported_parameters.include?(name)
    end

    def secret_values
      credentials = integration&.decrypted_credentials.to_h || {}
      headers = credentials["secret_headers"]
      [ api_key, credentials["api_key"], *(headers.is_a?(Hash) ? headers.values : []) ].filter_map do |value|
        text = value.to_s
        text.presence
      end.uniq
    end

    def options
      value = model_config["options"]
      value.is_a?(Hash) ? value : {}
    end

    def supports?(capability)
      model_config[capability.to_s]
    end

    def open_timeout
      bounded_number(config["open_timeout"], DEFAULT_OPEN_TIMEOUT, 1, 60)
    end

    def read_timeout
      bounded_number(config["read_timeout"], ProviderRegistry.definition(provider)[:read_timeout] || DEFAULT_READ_TIMEOUT, 1, 3600)
    end

    def max_request_bytes
      bounded_number(config["max_request_bytes"], DEFAULT_MAX_REQUEST_BYTES, 1024, 32.megabytes)
    end

    def max_response_bytes
      bounded_number(config["max_response_bytes"], DEFAULT_MAX_RESPONSE_BYTES, 1024, 16.megabytes)
    end

    def max_stream_bytes
      bounded_number(config["max_stream_bytes"], DEFAULT_MAX_STREAM_BYTES, 1024, 64.megabytes)
    end

    def max_retries
      bounded_number(config["max_retries"], 3, 0, 3).to_i
    end

    def auth_mode
      return "x-api-key" if provider == "anthropic" && api_key.present?

      custom? ? config.fetch("auth_mode", api_key.present? ? "bearer" : "none") : (api_key.present? ? "bearer" : "none")
    end

    def headers
      result = { "Accept" => "application/json" }
      case auth_mode
      when "bearer" then result["Authorization"] = "Bearer #{api_key}"
      when "x-api-key" then result["X-Api-Key"] = api_key
      when "none"
      else raise ProviderError.new("Unsupported authentication method.", code: "configuration_invalid")
      end
      Array(config["headers"]).each do |name, value|
        next unless ProviderRegistry.header_name_allowed?(name)
        next if ProviderRegistry.credential_header?(name) || ProviderRegistry.protected_header?(name)

        result[name.to_s] = value.to_s
      end
      integration&.decrypted_credentials.to_h.fetch("secret_headers", {}).each do |name, value|
        next unless ProviderRegistry.header_name_allowed?(name)
        next if ProviderRegistry.protected_header?(name)
        next if name.to_s.casecmp?(auth_header_name)

        result[name.to_s] = value.to_s
      end
      result["Content-Type"] = "application/json"
      validate_headers!(result)
      result
    end

    def endpoint_for(path, query: {})
      uri = URI.parse("#{base_url}/#{path.sub(%r{\A/+}, "")}")
      uri.query = URI.encode_www_form(query) if query.any?
      validated_url, address = ProviderEndpoint.validate_endpoint!(
        uri.to_s, local: ProviderRegistry.definition(provider)[:local],
        trusted_local: ProviderRegistry.definition(provider)[:local], resolve: !official_host?, allow_query: true
      )
      @pinned_addresses[validated_url] = address if address
      validated_url
    end

    def transport_fingerprint
      payload = {
        provider: provider, base_url: base_url, api_key: api_key, auth_mode: auth_mode,
        headers: config["headers"],
        secret_headers: integration&.decrypted_credentials.to_h["secret_headers"],
        open_timeout: open_timeout, read_timeout: read_timeout, max_request_bytes: max_request_bytes,
        max_response_bytes: max_response_bytes, max_stream_bytes: max_stream_bytes, max_retries: max_retries
      }
      Digest::SHA256.hexdigest(payload.to_json)
    end

    def inference_fingerprint
      payload = { transport: transport_fingerprint, model: model, api_family: api_family, model_config: model_config }
      Digest::SHA256.hexdigest(payload.to_json)
    end

    def pinned_address_for(url)
      @pinned_addresses[url]
    end

    def official_host?
      host = URI.parse(base_url).host.to_s.downcase
      ProviderRegistry::DEFINITIONS.values.any? do |definition|
        definition[:base_url] && URI.parse(definition[:base_url]).host.to_s.downcase == host
      end
    rescue URI::InvalidURIError
      false
    end

    private

    def normalize_base_url(value)
      uri = URI.parse(value)
      return value.sub(%r{/+\z}, "") unless uri.is_a?(URI::HTTP)

      segments = uri.path.to_s.split("/").reject(&:empty?)
      loop do
        operation = OPERATION_SUFFIXES.find do |suffix|
          segments.last(suffix.length) == suffix &&
            (version_segment?(segments[-suffix.length - 1]) || segments[-suffix.length - 1, suffix.length] == suffix)
        end
        if operation
          segments.pop(operation.length)
        elsif segments.length >= 2 && version_segment?(segments.last) && version_segment?(segments[-2])
          segments.pop
        elsif segments.length >= 3 && version_segment?(segments.last) && segments[-2] == "openai" &&
              version_segment?(segments[-3])
          segments.pop
        else
          break
        end
      end
      uri.path = segments.empty? ? "/" : "/#{segments.join('/')}"
      uri.to_s.sub(%r{/+\z}, "")
    rescue URI::InvalidURIError
      value.sub(%r{/+\z}, "")
    end

    def version_segment?(value)
      value.to_s.match?(VERSION_SEGMENT)
    end

    def configured_base_url
      return config["base_url"] if custom?
      return ENV.fetch("BONSAI_BASE_URL", "http://127.0.0.1:8910/v1") if provider == "bonsai" && model == "bonsai-27b"
      return ENV.fetch("BONSAI2_BASE_URL", "http://127.0.0.1:8080/v1") if provider == "bonsai"
      return ENV.fetch("OLLAMA_BASE_URL", "http://127.0.0.1:11434/v1") if provider == "ollama"

      environment_url = ENV["#{provider.upcase}_BASE_URL"]
      environment_url.presence || ProviderRegistry.definition(provider)[:base_url]
    end

    def validate!
      unless ProviderRegistry.builtin?(provider) || custom?
        raise ProviderError.new("Unknown model provider.", code: "unknown_provider")
      end
      raise ProviderError.new("A provider base URL is required.", code: "configuration_invalid") if base_url.blank?
      unless ProviderRegistry.api_family?(provider, api_family)
        raise ProviderError.new("The selected API family is not supported by this provider.", code: "configuration_invalid")
      end
      if custom? && config["base_url"].blank?
        raise ProviderError.new("A custom provider base URL is required.", code: "configuration_invalid")
      end
      unless %w[bearer x-api-key none].include?(auth_mode)
        raise ProviderError.new("Unsupported authentication method.", code: "configuration_invalid")
      end
      if custom? && auth_mode != "none" && api_key.blank?
        raise ProviderError.new("This authentication method requires an API key.", code: "configuration_invalid")
      end
    end

    def auth_header_name
      { "bearer" => "Authorization", "x-api-key" => "X-Api-Key" }[auth_mode]
    end

    def validate_headers!(values)
      values.each do |name, value|
        raise ProviderError.new("Invalid provider header.", code: "configuration_invalid") if name.to_s.match?(/[\r\n]/) || value.to_s.match?(/[\r\n]/)
      end
    end

    def bounded_number(value, default, minimum, maximum)
      number = Integer((value || default).to_s, 10)
      number.clamp(minimum, maximum)
    rescue ArgumentError, TypeError
      default
    end
  end
end
