# frozen_string_literal: true

module Llm
  class ProviderSettings
    Error = ModelCatalogue::Error
    PROVIDERS = ProviderRegistry::DEFINITIONS.keys.freeze
    ERROR_MESSAGES = {
      "invalid_credentials" => "The provider rejected these credentials. The saved key was not changed.",
      "credentials_unavailable" => "Enter an API key before saving.",
      "provider_authentication_failed" => "The provider rejected the configured credentials.",
      "provider_access_restricted" => "The provider account is not permitted to use this model or endpoint.",
      "provider_credit_insufficient" => "The provider account has insufficient credits or quota.",
      "provider_rate_limited" => "The provider rate limit was reached. Try again later.",
      "provider_timeout" => "Provider discovery timed out. Try again later.",
      "provider_unavailable" => "The provider is unavailable. Try again later.",
      "invalid_provider_response" => "The provider returned an invalid model catalogue.",
      "catalogue_page_limit" => "The provider catalogue exceeds the discovery limit.",
      "discovery_unsupported" => "Model discovery is not supported for this connection.",
      "local_endpoint_required" => "Bonsai discovery requires a host-local endpoint.",
      "endpoint_invalid" => "Enter a valid provider base URL.",
      "endpoint_forbidden" => "This provider endpoint is not permitted.",
      "configuration_invalid" => "The provider connection configuration is invalid.",
      "unknown_provider" => "Unknown provider.",
      "invalid_provider_settings" => "Invalid provider settings.",
      "invalid_model_settings" => "Invalid model settings.",
      "inference_unverified" => "Verify this model with a successful real inference request before making it the organization default."
    }.freeze

    def initialize(organization:, actor:)
      @organization = organization
      @actor = actor
      @catalogue = ModelCatalogue.new(organization)
    end

    def call(action: :inventory, provider_id: nil, api_key: nil, is_active: nil, disabled_models: nil,
             model_id: nil, custom_connection: nil, model_config: nil)
      authorize!
      provider = provider_id.to_s
      result = case action.to_sym
      when :inventory then inventory
      when :refresh then refresh
      when :save_key then save_key(provider, api_key)
      when :connection then set_connection(provider, is_active)
      when :models then set_disabled_models(provider, disabled_models)
      when :model then set_model(provider, model_id, is_active)
      when :default then set_default(provider, model_id)
      when :save_custom then save_custom(provider, custom_connection || {})
      when :save_model then save_model(provider, model_id, model_config || {})
      when :verify_model then verify_model(provider, model_id)
      else raise Error.new("invalid_provider_settings", "Invalid provider settings.")
      end
      result
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      raise Error.new("provider_settings_not_saved", "Provider settings could not be saved.")
    rescue ProviderError => e
      raise Error.new(e.code.to_s, e.message, retryable: e.retryable?)
    end

    private

    def authorize!
      raise Error.new("owner_required", "Organization owner authorization required.") unless @actor && @organization&.owner_id == @actor.id
    end

    def inventory(refresh: false)
      data = @catalogue.owner_inventory(actor: @actor, refresh: refresh)
      connections = model_connections.index_by(&:provider)
      providers = (PROVIDERS + connections.keys).uniq.map do |provider|
        connection = connections[provider]
        discovered = data[:providers].find { |entry| entry[:provider_id] == provider }
        config = connection&.config.to_h || {}
        environment_key = ProviderRegistry.environment_key(provider)
        configured = connection&.api_key.present? || environment_key.present? || ProviderRegistry.credentials_key(provider).present? ||
          ProviderRegistry.default_api_key(provider).present? ||
          (ProviderRegistry.custom?(provider) && connection && config.fetch("auth_mode", "none") == "none")
        (discovered || { provider_id: provider, provider_name: ProviderRegistry.name(provider), custom: ProviderRegistry.custom?(provider),
                         connection_status: "unavailable", readiness: "unavailable", inference_ready: false,
                         billing_blocked: false, error_code: nil }).merge(
          configured: configured, is_active: connection&.is_active? || false, has_connection: connection.present?,
          discovery_supported: discovery_supported?(provider, connection),
          last_verified_at: ProviderRegistry.manual_only?(provider) ? nil : config["last_verified_at"],
          last_catalogue_verified_at: ProviderRegistry.manual_only?(provider) ? nil : config["last_verified_at"],
          last_verification_attempt_at: ProviderRegistry.manual_only?(provider) ? nil : config["last_verification_attempt_at"],
          verification_error_code: ProviderRegistry.manual_only?(provider) ? nil : safe_code(config["last_verification_error"]),
          error: ERROR_MESSAGES[discovered&.dig(:error_code)],
          custom_config: custom_config(provider, connection)
        )
      end
      data.merge(providers: providers, default_model: @organization.settings["default_model"])
    end

    def custom_config(provider, connection)
      return unless ProviderRegistry.custom?(provider) && connection

      config = connection.config.to_h
      credentials = connection.decrypted_credentials.to_h
      secret_headers = credentials["secret_headers"]
      secret_values = [ connection.api_key, credentials["api_key"] ]
      secret_values.concat(secret_headers.values) if secret_headers.is_a?(Hash)
      {
        name: connection.name, base_url: config["base_url"], auth_mode: config.fetch("auth_mode", "bearer"),
        discovery_enabled: config.fetch("discovery_enabled", true), open_timeout: config["open_timeout"],
        read_timeout: config["read_timeout"], max_request_bytes: config["max_request_bytes"],
        max_response_bytes: config["max_response_bytes"], max_stream_bytes: config["max_stream_bytes"],
        max_retries: config["max_retries"], headers: ModelCatalogue.redact(public_headers(config), secret_values),
        secret_header_names: secret_headers.is_a?(Hash) ? secret_headers.keys : []
      }
    end

    def public_headers(config)
      headers = config["headers"]
      return {} unless headers.is_a?(Hash)

      headers.select do |name, _value|
        ProviderRegistry.header_name_allowed?(name) && !ProviderRegistry.credential_header?(name) &&
          !ProviderRegistry.protected_header?(name)
      end
    end

    def model_connections
      @organization.tool_integrations.to_a.select do |connection|
        ProviderRegistry.builtin?(connection.provider) || ProviderRegistry.custom?(connection.provider)
      end
    end

    def discovery_supported?(provider, connection)
      return false if ProviderRegistry.custom?(provider) && connection&.config&.fetch("discovery_enabled", true) == false

      ProviderRegistry.builtin?(provider) ? ModelCatalogue::DISCOVERY_PROVIDERS.include?(provider) : true
    end

    def provider!(provider)
      raise Error.new("unknown_provider", "Unknown provider.") unless ProviderRegistry.builtin?(provider) || ProviderRegistry.custom?(provider)
    end

    def custom!(provider)
      raise Error.new("unknown_provider", "Unknown custom provider.") unless ProviderRegistry.custom?(provider)
    end

    def connection!(provider)
      provider!(provider)
      @organization.tool_integrations.find_by(provider: provider) ||
        raise(Error.new("connection_required", "Configure this provider connection first."))
    end

    def safe_code(code)
      ERROR_MESSAGES.key?(code) ? code : nil
    end

    def transport_fingerprint(connection)
      return unless connection&.persisted?

      ProviderConnection.new(provider: connection.provider, integration: connection, model: "discovery").transport_fingerprint
    rescue ProviderError
      nil
    end

    def invalidate_inference(config, model_id: nil)
      config = config.to_h.dup
      verifications = config.fetch("inference_verifications", {})
      config["inference_verifications"] = model_id ? verifications.except(model_id) : {}
      return config if model_id && config["last_inference_model_id"] != model_id

      %w[last_inference_succeeded_at last_inference_attempt_at last_inference_error_code
         last_inference_model_id last_inference_configuration_fingerprint].each { |name| config.delete(name) }
      config
    end

    def verify(provider, key, connection)
      rows = @catalogue.verify_provider(provider, key, connection)
      [ rows, Time.current.iso8601 ]
    rescue Error => error
      if connection&.persisted?
        connection.with_lock do
          connection.update!(config: connection.config.merge(
            "last_verification_attempt_at" => Time.current.iso8601, "last_verification_error" => safe_code(error.code)))
        end
      end
      raise Error.new(error.code, ERROR_MESSAGES.fetch(error.code, "Provider verification could not be completed."),
        retryable: error.retryable)
    end

    def save_key(provider, candidate)
      provider!(provider)
      raise Error.new("unknown_provider", "Custom endpoints use the custom connection form.") if ProviderRegistry.custom?(provider)
      connection = @organization.tool_integrations.find_by(provider: provider)
      candidate = "" if candidate.nil?
      unless candidate.is_a?(String) && candidate.bytesize <= 8192
        raise Error.new("invalid_credentials", "Enter a valid API key before saving.")
      end
      previous_fingerprint = transport_fingerprint(connection)
      submitted_key = candidate.strip
      key = submitted_key.presence || connection&.api_key.presence || ProviderRegistry.environment_key(provider) ||
        ProviderRegistry.credentials_key(provider) || ProviderRegistry.default_api_key(provider)
      raise Error.new("credentials_unavailable", "Enter an API key before saving.") if key.blank?

      rows = verified_at = nil
      unless ProviderRegistry.manual_only?(provider)
        rows, verified_at = verify(provider, key, connection)
      end
      @organization.with_lock do
        connection = @organization.tool_integrations.find_or_initialize_by(provider: provider)
        connection.name = "#{ProviderRegistry.name(provider)} API" if connection.name.blank?
        credentials = connection.credentials.to_h
        credentials["api_key"] = key if submitted_key.present?
        connection.credentials = credentials
        connection.is_active = true
        config = if ProviderRegistry.manual_only?(provider)
                   connection.config.to_h.except("discovered_models", "last_verified_at",
                     "last_verification_attempt_at", "last_verification_error")
        else
                   connection.config.to_h.merge("discovered_models" => rows, "last_verified_at" => verified_at,
                     "last_verification_attempt_at" => verified_at, "last_verification_error" => nil)
        end
        ProviderConnection.new(provider: provider, integration: connection, model: "discovery")
        config = invalidate_inference(config) if previous_fingerprint != transport_fingerprint(connection)
        connection.config = config
        connection.save!
      end
      notice = if ProviderRegistry.manual_only?(provider)
                 "#{ProviderRegistry.name(provider)} credentials saved. Catalogue discovery is unavailable; add model IDs manually."
      else
                 "#{ProviderRegistry.name(provider)} credentials saved; catalogue discovery succeeded."
      end
      { notice: notice }
    end

    def save_custom(provider, params)
      custom!(provider)
      params = params.to_h.deep_symbolize_keys
      connection = @organization.tool_integrations.find_or_initialize_by(provider: provider)
      previous_fingerprint = transport_fingerprint(connection)
      config = connection.config.to_h.dup
      config["base_url"] = params[:base_url].to_s.strip if params.key?(:base_url)
      config["auth_mode"] = params[:auth_mode].to_s if params.key?(:auth_mode)
      %w[discovery_enabled open_timeout read_timeout max_request_bytes max_response_bytes max_stream_bytes max_retries].each do |name|
        config[name] = params[name.to_sym] if params.key?(name.to_sym)
      end
      config["discovery_enabled"] = boolean!(config["discovery_enabled"]) if config.key?("discovery_enabled")
      config["headers"] = safe_headers(params[:headers]) if params.key?(:headers)
      credentials = connection.credentials.to_h.dup
      credentials["api_key"] = params[:api_key].to_s.strip if params[:api_key].present?
      if params.key?(:secret_headers)
        credentials["secret_headers"] = merge_secret_headers(credentials["secret_headers"], params[:secret_headers],
          auth_mode: config.fetch("auth_mode", "bearer"))
      end
      connection.credentials = credentials
      connection.config = config
      connection.name = params[:name].to_s.strip.presence || connection.name.presence || "#{ProviderRegistry.name(provider)} API"
      connection.is_active = true if connection.new_record?
      ProviderConnection.new(provider: provider, integration: connection, model: "discovery")
      ProviderEndpoint.validate_url!(config["base_url"])

      if config.fetch("discovery_enabled", true)
        rows, verified_at = verify(provider, connection.api_key, connection)
        config = connection.config.merge("discovered_models" => rows, "last_verified_at" => verified_at,
          "last_verification_attempt_at" => verified_at, "last_verification_error" => nil)
      else
        config["last_verification_attempt_at"] = Time.current.iso8601
        config["last_verification_error"] = nil
      end
      config = invalidate_inference(config) if previous_fingerprint != transport_fingerprint(connection)
      connection.config = config
      connection.save!
      { notice: "Custom provider connection saved. Discovery does not verify inference." }
    end

    def safe_headers(value)
      raise Error.new("configuration_invalid", "Invalid provider headers.") unless value.is_a?(Hash) && value.size <= 20

      value.each_with_object({}) do |(name, header_value), result|
        unless name.to_s.match?(/\A[A-Za-z0-9-]+\z/) && ProviderRegistry.header_name_allowed?(name) &&
               !ProviderRegistry.credential_header?(name) && !ProviderRegistry.protected_header?(name)
          raise Error.new("configuration_invalid", "Only documented non-secret provider headers are allowed.")
        end
        unless header_value.is_a?(String) && header_value.bytesize <= 4096 && header_value.match?(/\A[^\r\n]*\z/)
          raise Error.new("configuration_invalid", "Invalid provider header value.")
        end
        result[name.to_s] = header_value
      end
    end

    def merge_secret_headers(existing, submitted, auth_mode:)
      existing = existing.is_a?(Hash) ? existing : {}
      unless submitted.is_a?(Hash) && submitted.size <= 20
        raise Error.new("configuration_invalid", "Invalid secret header settings.")
      end
      auth_header = { "bearer" => "Authorization", "x-api-key" => "X-Api-Key" }[auth_mode]
      submitted.each do |name, value|
        unless name.to_s.match?(/\A[A-Za-z0-9-]+\z/) && ProviderRegistry.header_name_allowed?(name) &&
               !ProviderRegistry.protected_header?(name) && !name.to_s.casecmp?(auth_header)
          raise Error.new("configuration_invalid", "Only documented secret header names are allowed.")
        end
        next if value.to_s.blank?

        unless value.is_a?(String) && value.bytesize <= 8192 && value.match?(/\A[^\r\n]*\z/)
          raise Error.new("configuration_invalid", "Invalid secret header value.")
        end
        existing[name.to_s] = value
      end
      existing
    end

    def save_model(provider, model_id, params)
      connection = connection!(provider)
      model_id = model_id.to_s.strip
      unless model_id.bytesize.between?(1, 256) && model_id.match?(/\A[^\r\n]+\z/)
        raise Error.new("invalid_model_settings", "Enter a valid model ID.")
      end
      params = params.to_h.deep_symbolize_keys
      models = connection.config["models"].is_a?(Hash) ? connection.config["models"] : {}
      existing = models[model_id].is_a?(Hash) ? models[model_id] : {}
      family = if params.key?(:api_family)
                 params[:api_family].to_s.strip.presence || ProviderRegistry.default_api_family(provider)
      else
                 existing["api_family"].presence || ProviderRegistry.default_api_family(provider)
      end
      unless ProviderRegistry.api_family?(provider, family)
        raise Error.new("invalid_model_settings", "Select a supported API family.")
      end
      allowed = ProviderRegistry.supported_parameters(provider, family)
      changes = {}
      changes["api_family"] = params[:api_family].to_s.strip.presence if params.key?(:api_family)
      %w[display_name description].each do |name|
        changes[name] = bounded_text(params[name.to_sym], name == "display_name" ? 256 : 2048) if params.key?(name.to_sym)
      end
      (ModelCatalogue::CAPABILITIES - %w[reasoning_parameters]).each do |name|
        changes[name] = optional_boolean(params[name.to_sym]) if params.key?(name.to_sym)
      end
      %w[context_window max_output_tokens].each do |name|
        changes[name] = optional_positive_integer(params[name.to_sym]) if params.key?(name.to_sym)
      end
      %w[free_tier access_restricted].each do |name|
        changes[name] = optional_boolean(params[name.to_sym]) if params.key?(name.to_sym)
      end
      if params.key?(:supported_parameters)
        parameters = params[:supported_parameters].to_s.strip.blank? ? nil : array_parameter(params[:supported_parameters])
        raise Error.new("invalid_model_settings", "Unsupported request parameter.") if parameters && !(parameters - allowed).empty?

        changes["supported_parameters"] = parameters
      end
      if params.key?(:reasoning_parameters)
        changes["reasoning_parameters"] = params[:reasoning_parameters].to_s.strip.blank? ? nil :
          array_parameter(params[:reasoning_parameters])
      end
      if params.key?(:options)
        changes["options"] = params[:options].to_s.strip.blank? ? nil : safe_options(params[:options], allowed)
      end
      if params.key?(:rate_limits)
        changes["rate_limits"] = params[:rate_limits].to_s.strip.blank? ? nil :
          safe_metadata_hash(params[:rate_limits], "rate_limits")
      end
      metadata = apply_metadata_changes(existing, changes)
      ProviderConnection.new(provider: provider, integration: connection, model: model_id, model_config: metadata)
      @organization.with_lock do
        connection.with_lock do
          connection.reload
          models = connection.config["models"].is_a?(Hash) ? connection.config["models"].dup : {}
          existing = models[model_id].is_a?(Hash) ? models[model_id] : {}
          updated = apply_metadata_changes(existing, changes)
          config = connection.config.merge("models" => models.merge(model_id => updated))
          config = invalidate_inference(config, model_id: model_id) if existing != updated
          connection.update!(config: config)
        end
      end
      { notice: "Manual model metadata saved. No inference request was sent." }
    end

    def apply_metadata_changes(existing, changes)
      existing.dup.tap do |metadata|
        changes.each do |name, value|
          value.nil? ? metadata.delete(name) : metadata[name] = value
        end
      end
    end

    def safe_options(value, allowed)
      value = JSON.parse(value) if value.is_a?(String)
      unless value.is_a?(Hash) && value.size <= 50 && value.to_json.bytesize <= 16.kilobytes
        raise Error.new("invalid_model_settings", "Model options must be a bounded JSON object.")
      end

      value.each_with_object({}) do |(name, option_value), result|
        raise Error.new("invalid_model_settings", "Unsupported model option.") unless allowed.include?(name.to_s)

        result[name.to_s] = option_value
      end
    rescue JSON::ParserError
      raise Error.new("invalid_model_settings", "Model options must be valid JSON.")
    end

    def safe_metadata_hash(value, label)
      value = JSON.parse(value) if value.is_a?(String)
      unless value.is_a?(Hash) && value.size <= 50 && value.to_json.bytesize <= 16.kilobytes
        raise Error.new("invalid_model_settings", "Invalid #{label} metadata.")
      end
      value
    rescue JSON::ParserError
      raise Error.new("invalid_model_settings", "Invalid #{label} metadata.")
    end

    def array_parameter(value)
      value = value.split(",").map(&:strip) if value.is_a?(String)
      unless value.is_a?(Array) && value.size <= 50 && value.all? { |item| item.is_a?(String) && item.bytesize <= 128 }
        raise Error.new("invalid_model_settings", "Invalid supported parameters.")
      end
      value.uniq
    end

    def bounded_text(value, limit)
      return nil if value.nil? || value.to_s.strip.blank?

      text = value.to_s.strip
      raise Error.new("invalid_model_settings", "Model metadata is too long.") if text.bytesize > limit

      text
    end

    def optional_boolean(value)
      return nil if value.nil? || value == ""
      return true if value == true || value == "true"
      return false if value == false || value == "false"

      raise Error.new("invalid_model_settings", "Invalid model capability value.")
    end

    def optional_positive_integer(value)
      return nil if value.nil? || value == ""

      number = Integer(value, 10)
      raise Error.new("invalid_model_settings", "Model limits must be positive integers.") unless number.positive? && number <= 100_000_000

      number
    rescue ArgumentError, TypeError
      raise Error.new("invalid_model_settings", "Model limits must be positive integers.")
    end

    def verify_model(provider, model_id)
      connection = connection!(provider)
      raise Error.new("connection_inactive", "Enable this provider connection before verifying its model.") unless connection.is_active?

      model = @catalogue.resolve!({ "provider_id" => provider, "model_id" => model_id })
      unless model[:availability_status] == "available"
        raise Error.new("model_unavailable", "This model is unavailable.")
      end
      api_key = connection.api_key.presence || ProviderRegistry.environment_key(provider) ||
        ProviderRegistry.credentials_key(provider) || ProviderRegistry.default_api_key(provider)
      selected_connection = ProviderConnection.new(provider: provider, integration: connection, api_key: api_key,
        model: model_id)
      client = Client.new(provider: provider, model: model_id, connection: selected_connection, max_tokens: 16)
      begin
        result = client.chat(messages: [ { role: "user", content: "Reply with OK." } ], tools: [], max_tokens: 16)
        if result[:content].to_s.strip.empty? && Array(result[:tool_calls]).empty?
          raise ProviderError.new(ProviderError::MESSAGES["invalid_provider_response"], code: "invalid_provider_response")
        end
        unless InferenceTracker.record(selected_connection, model_id, api_family: selected_connection.api_family,
          fingerprint: selected_connection.inference_fingerprint)
          raise Error.new("provider_settings_not_saved", "Inference succeeded but its verification state could not be saved.")
        end
        { notice: "Real inference succeeded. This model is now verified." }
      rescue ProviderError => e
        InferenceTracker.record(selected_connection, model_id, error: e, api_family: selected_connection.api_family,
          fingerprint: selected_connection.inference_fingerprint)
        raise Error.new(e.code.to_s, e.message, retryable: e.retryable?)
      end
    end

    def boolean!(value)
      return true if value == true || value == "true" || value == "1"
      return false if value == false || value == "false" || value == "0"

      raise Error.new("invalid_provider_settings", "Invalid provider settings.")
    end

    def set_connection(provider, value)
      connection = connection!(provider)
      active = boolean!(value)
      @organization.with_lock do
        connection.with_lock { connection.update!(is_active: active) }
        clear_default(provider) unless active
      end
      { notice: "#{ProviderRegistry.name(provider)} connection #{active ? 'enabled' : 'disabled'}." }
    end

    def model_inventory(provider)
      connection!(provider)
      inventory[:models].select { |model| model[:provider_id] == provider }
    end

    def set_model(provider, model_id, value)
      enabled = boolean!(value)
      models = model_inventory(provider)
      unless models.any? { |model| model[:model_id] == model_id && model[:manageable] }
        raise Error.new("model_unavailable", "This discovered model cannot be managed.")
      end
      update_disabled_models(provider) do |ids|
        enabled ? ids - [ model_id ] : (ids + [ model_id ]).uniq
      end
    end

    def set_disabled_models(provider, ids)
      unless ids.is_a?(Array) && ids.size <= 1000 && ids.all? { |id| id.is_a?(String) && id.bytesize <= 256 }
        raise Error.new("invalid_model_settings", "Invalid model settings.")
      end
      known = model_inventory(provider).pluck(:model_id)
      raise Error.new("model_unavailable", "Only discovered models can be disabled.") unless (ids - known).empty?

      update_disabled_models(provider) { |_current| ids.uniq }
    end

    def update_disabled_models(provider)
      connection = connection!(provider)
      @organization.with_lock do
        connection.with_lock do
          ids = yield Array(connection.config["disabled_models"])
          connection.update!(config: connection.config.merge("disabled_models" => ids))
          default = @organization.settings["default_model"]
          clear_default(provider) if default && ids.include?(default["model_id"])
        end
      end
      { notice: "#{ProviderRegistry.name(provider)} model settings saved." }
    end

    def clear_default(provider)
      return unless @organization.settings.dig("default_model", "provider_id") == provider

      @organization.update!(settings: @organization.settings.except("default_model"))
    end

    def set_default(provider, model_id)
      @organization.with_lock do
        model = @catalogue.resolve!({ "provider_id" => provider, "model_id" => model_id })
        raise Error.new("inference_unverified", ERROR_MESSAGES["inference_unverified"]) unless model[:inference_status] == "verified"

        @organization.update!(settings: @organization.settings.merge(
          "default_model" => { "provider_id" => provider, "model_id" => model_id }))
      end
      { notice: "Organization default model saved." }
    end

    def refresh
      data = inventory(refresh: true)
      model_connections.each do |connection|
        next unless connection.is_active?
        next if ProviderRegistry.manual_only?(connection.provider)

        provider = data[:providers].find { |entry| entry[:provider_id] == connection.provider }
        verified_at = data[:catalogue_updated_at]
        connection.with_lock do
          config = connection.config.merge("last_verification_attempt_at" => verified_at,
            "last_verification_error" => safe_code(provider[:error_code]))
          if provider[:connection_status] == "connected"
            rows = data[:models].select { |model| model[:provider_id] == connection.provider }.map do |model|
              { "id" => model[:model_id], "display_name" => model[:display_name], "description" => model[:model_description],
                "lifecycle" => model[:lifecycle], "context_window" => model[:context_window],
                "max_output_tokens" => model[:max_output_tokens], "supported_parameters" => model[:supported_parameters],
                "free_tier" => model[:free_tier], "zero_priced" => model[:zero_priced],
                "rate_limits" => model[:rate_limits] }
                .merge(ModelCatalogue::CAPABILITIES.index_with { |name| model[name.to_sym] }).compact
            end
            config.merge!("last_verified_at" => verified_at, "discovered_models" => rows)
          end
          connection.update!(config: config)
        end
      end
      { notice: "Provider catalogues refreshed; manual-only providers were left unchanged. No inference request was sent." }
    end
  end
end
