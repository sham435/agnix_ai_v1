# frozen_string_literal: true

module Llm
  class ModelCatalogue
    class Error < StandardError
      attr_reader :code, :retryable

      def initialize(code, message, retryable: false)
        @code = code
        @retryable = retryable
        super(message)
      end
    end

    CACHE_TTL = 5.minutes
    MAX_PAGES = 20
    CAPABILITIES = %w[
      supports_streaming supports_tools supports_vision supports_images supports_json_mode
      supports_reasoning reasoning_parameters supports_parallel_tool_calls
    ].freeze
    DISCOVERY_PROVIDERS = %w[bonsai anthropic openai openrouter opencode google groq cerebras].freeze
    UNSELECTABLE_LIFECYCLES = %w[retired deprecated disabled].freeze
    AUTHENTICATION_ERRORS = %w[invalid_credentials provider_authentication_failed].freeze
    OPENCODE_FREE_CHAT_MODELS = %w[
      big-pickle tidepool-alpha-free iceman-free deepseek-v4.1-flash-free beam-free flint-40b-free
      hy4-flash-free mimo-v2.6-flash-free nemotron-3.5-lightning-free nemotron-3.5-super-vl-free
    ].freeze
    DISCOVERY_FIELDS = %w[
      id display_name description lifecycle context_window max_output_tokens supported_parameters
      reasoning_parameters free_tier zero_priced rate_limits access_restricted
    ].freeze

    def self.redact(value, secrets, depth = 0)
      secrets = Array(secrets).filter_map { |secret| secret.to_s.presence }.uniq
      return nil if depth > 4
      return value if value == true || value == false || value.is_a?(Numeric)

      case value
      when String
        return nil if secrets.any? { |secret| value.include?(secret) }

        value.bytesize <= 2048 ? value : nil
      when Array
        value.first(100).map { |item| redact(item, secrets, depth + 1) }.compact
      when Hash
        value.first(100).each_with_object({}) do |(name, item), clean|
          clean_name = name.to_s
          next if secrets.any? { |secret| clean_name.include?(secret) }

          clean_item = redact(item, secrets, depth + 1)
          clean[clean_name.slice(0, 128)] = clean_item unless clean_item.nil?
        end
      end
    end

    def initialize(organization)
      @organization = organization
    end

    def call(refresh: false)
      inventory = catalogue(refresh: refresh)
      inventory.merge(models: inventory[:models].select { |model| model[:availability_status] == "available" })
    end

    def owner_inventory(actor:, refresh: false)
      raise Error.new("owner_required", "Organization owner authorization required.") unless actor && @organization.owner_id == actor.id

      inventory = catalogue(refresh: refresh)
      connections = @organization.tool_integrations.index_by(&:provider)
      inventory[:models].each do |model|
        connection = connections[model[:provider_id]]
        metadata = connection&.config&.fetch("models", {})&.fetch(model[:model_id], {}) || {}
        options = metadata["options"].is_a?(Hash) ? metadata["options"] : {}
        model[:editable_options] = self.class.redact(options, credential_secrets(model[:provider_id], connection))
      end
      inventory
    end

    def verify_provider(provider, key, connection = nil)
      if ProviderRegistry.custom?(provider)
        raise Error.new("discovery_unsupported", "Model discovery is not supported for this connection.") if connection&.config&.fetch("discovery_enabled", true) == false
      elsif !DISCOVERY_PROVIDERS.include?(provider)
        raise Error.new("discovery_unsupported", "Model discovery is not supported for this connection.")
      end
      if provider != "bonsai" && key.blank? && !(ProviderRegistry.custom?(provider) && connection&.config&.fetch("auth_mode", "none") == "none")
        raise Error.new("credentials_unavailable", "Enter an API key before saving.")
      end
      sanitize_rows(discover_provider(provider, key, connection), credential_secrets(provider, connection, key))
    end

    def resolve!(selection, tools: false)
      model = call[:models].find { |entry| entry[:provider_id] == selection["provider_id"] && entry[:model_id] == selection["model_id"] }
      unless model && model[:availability_status] == "available"
        raise Error.new("model_unavailable", "Selected model is unavailable. Refresh the catalogue and choose another model.")
      end
      if tools && model[:supports_tools] != true
        raise Error.new("capability_unverified", "Tool support is not verified for this model. Choose a model with verified tool support.")
      end
      model
    end

    private

    def catalogue(refresh:)
      connections = @organization.tool_integrations.order(:id).to_a.select do |connection|
        ProviderRegistry.builtin?(connection.provider) || ProviderRegistry.custom?(connection.provider)
      end
      environment = ProviderRegistry::DEFINITIONS.keys.map do |provider|
        [ ENV["#{provider.upcase}_BASE_URL"], ProviderRegistry.environment_key(provider),
          ProviderRegistry.credentials_key(provider) ]
      end
      fingerprint = Digest::SHA256.hexdigest(connections.map { |c| [ c.id, c.updated_at.to_f, c.is_active, c.config ] }.to_json +
        @organization.settings.to_json + environment.to_json + [ ENV["BONSAI2_BASE_URL"], ENV["BONSAI_MODEL"] ].to_json)
      key = [ "model-catalogue-v4", @organization.id, fingerprint ]
      Rails.cache.delete(key) if refresh
      Rails.cache.fetch(key, expires_in: CACHE_TTL) { discover(connections) }
    end

    def sanitize_rows(rows, secrets)
      rows.filter_map do |row|
        unless row.is_a?(Hash) && row["id"].is_a?(String) && row["id"].present? && row["id"].bytesize <= 256
          raise Error.new("invalid_provider_response", "Invalid model catalogue.")
        end
        clean = self.class.redact(row.slice(*DISCOVERY_FIELDS, *CAPABILITIES), secrets)
        next unless clean["id"].is_a?(String) && clean["id"].present? && clean["id"].bytesize <= 256

        clean.delete_if { |_name, value| value.nil? }
        %w[display_name description lifecycle].each do |name|
          clean.delete(name) unless clean[name].is_a?(String) && clean[name].bytesize <= 2048
        end
        %w[context_window max_output_tokens].each do |name|
          clean.delete(name) unless clean[name].is_a?(Integer) && clean[name].positive?
        end
        (CAPABILITIES - %w[reasoning_parameters]).each { |name| clean.delete(name) unless [ true, false ].include?(clean[name]) }
        %w[free_tier zero_priced access_restricted].each { |name| clean.delete(name) unless [ true, false ].include?(clean[name]) }
        %w[supported_parameters reasoning_parameters].each do |name|
          clean.delete(name) unless clean[name].is_a?(Array) && clean[name].all? { |value| value.is_a?(String) }
        end
        clean["rate_limits"] = {} unless clean["rate_limits"].is_a?(Hash)
        clean
      end
    end

    def credential_secrets(provider, connection, key = nil)
      credentials = connection&.decrypted_credentials.to_h || {}
      headers = credentials["secret_headers"]
      selected_key = key.presence || connection&.api_key.presence || ProviderRegistry.environment_key(provider) ||
        ProviderRegistry.credentials_key(provider) || ProviderRegistry.default_api_key(provider)
      [ selected_key, credentials["api_key"], *(headers.is_a?(Hash) ? headers.values : []) ].filter_map do |value|
        value.to_s.presence
      end.uniq
    end

    def discover(connections)
      providers = []
      models = []
      by_provider = connections.index_by(&:provider)
      configured_builtins = ProviderRegistry::DEFINITIONS.keys.select do |provider|
        ProviderRegistry.environment_key(provider).present? || ProviderRegistry.credentials_key(provider).present?
      end
      provider_ids = ([ "bonsai" ] + configured_builtins + connections.map(&:provider)).uniq
      provider_ids.each do |provider|
        connection = by_provider[provider]
        entry = { provider_id: provider, provider_name: ProviderRegistry.name(provider), custom: ProviderRegistry.custom?(provider),
                  connection_status: "unavailable", error_code: nil, rate_limits: {} }
        providers << entry
        paused = connection && !connection.is_active?
        config = connection&.config.to_h || {}
        key = connection&.api_key.presence || ProviderRegistry.environment_key(provider) || ProviderRegistry.credentials_key(provider) ||
          ProviderRegistry.default_api_key(provider)
        secrets = credential_secrets(provider, connection, key)
        manual_rows = manual_model_rows(config, secrets)
        rows = manual_rows
        discovered_at = nil
        if paused
          cached_rows = ProviderRegistry.manual_only?(provider) ? [] : sanitize_rows(Array(config["discovered_models"]), secrets)
          rows = cached_rows + manual_rows
          entry[:connection_status] = "disabled"
        elsif ProviderRegistry.manual_only?(provider)
          if key.present?
            entry[:connection_status] = "connected"
          else
            entry[:error_code] = "credentials_unavailable"
          end
        else
          begin
            if provider == "bonsai" || connection || key.present?
              if ProviderRegistry.custom?(provider) && config.fetch("discovery_enabled", true) == false
                rows = sanitize_rows(Array(config["discovered_models"]), secrets) + manual_rows
                entry[:connection_status] = "connected"
              else
                discovered = verify_provider(provider, key, connection)
                rows = discovered + manual_rows
                discovered_at = Time.current.iso8601
                entry[:connection_status] = "connected"
              end
            elsif key.blank?
              entry[:error_code] = "credentials_unavailable"
            end
          rescue Error => e
            entry[:error_code] = e.code
            rows = sanitize_rows(Array(config["discovered_models"]), secrets) + manual_rows
          end
        end
        legacy_current = legacy_inference_current?(provider, connection, config, key)
        disabled = Array(config["disabled_models"])
        rows.uniq { |row| row["id"] }.each do |row|
          model_id = row["id"]
          models_config = config["models"].is_a?(Hash) ? config["models"] : {}
          metadata = self.class.redact(models_config.fetch(model_id, {}), secrets)
          metadata = {} unless metadata.is_a?(Hash)
          model_disabled = disabled.include?(model_id)
          retired = UNSELECTABLE_LIFECYCLES.include?(row["lifecycle"])
          restricted = metadata["access_restricted"] == true || row["access_restricted"] == true
          configuration_invalid = %w[configuration_invalid endpoint_invalid endpoint_forbidden unknown_provider].include?(entry[:error_code])
          authentication_invalid = AUTHENTICATION_ERRORS.include?(entry[:error_code])
          credentials_missing = ProviderRegistry.manual_only?(provider) && key.blank?
          availability = if retired
                           "retired"
          elsif restricted
                           "access_restricted"
          elsif configuration_invalid
                           "configuration_invalid"
          elsif credentials_missing || authentication_invalid
                           "unavailable"
          else
                           paused || model_disabled ? "disabled" : "available"
          end
          fingerprint = inference_fingerprint(provider, connection, model_id, key)
          verification = inference_verification(config, model_id, fingerprint)
          model = {
            provider_id: provider, provider_name: ProviderRegistry.name(provider), model_id: model_id,
            display_name: row["display_name"].presence || metadata["display_name"].presence || model_id,
            model_description: row["description"] || metadata["description"], lifecycle: row["lifecycle"] || "unknown",
            connection_status: entry[:connection_status], availability_status: availability,
            disabled: model_disabled, access_restricted: restricted, manageable: connection.present? && !retired,
            inference_status: inference_status_for(config, model_id, fingerprint: fingerprint,
              legacy_current: legacy_current, provider_error: entry[:error_code]),
            inference_verified_at: verification["succeeded_at"], last_inference_attempt_at: verification["attempt_at"],
            last_inference_error_code: authentication_invalid ? entry[:error_code] : verification["error_code"],
            api_family: metadata["api_family"].presence || ProviderRegistry.default_api_family(provider),
            supported_parameters: metadata["supported_parameters"] || row["supported_parameters"],
            option_names: metadata["options"].is_a?(Hash) ? metadata["options"].keys : [],
            context_window: metadata["context_window"] || row["context_window"],
            max_output_tokens: metadata["max_output_tokens"] || row["max_output_tokens"],
            free_tier: metadata.fetch("free_tier", row["free_tier"]),
            zero_priced: metadata.fetch("zero_priced", row["zero_priced"]),
            rate_limits: metadata["rate_limits"] || row["rate_limits"] || {},
            is_default: @organization.settings["default_model"] == { "provider_id" => provider, "model_id" => model_id },
            last_discovered_at: discovered_at || (ProviderRegistry.manual_only?(provider) ? nil : config["last_verified_at"]),
            local: provider.in?(%w[bonsai ollama])
          }
          CAPABILITIES.each { |name| model[name.to_sym] = metadata.fetch(name, row[name]) }
          models << model
        end
        entry[:inference_ready] = !paused && models.any? { |model| model[:provider_id] == provider && model[:inference_status] == "verified" }
        entry[:billing_blocked] = !paused && (legacy_current && inference_credit_blocked?(config) ||
          models.any? { |model| model[:provider_id] == provider && model[:inference_status] == "billing_blocked" })
        entry[:access_restricted] = entry[:error_code] == "provider_access_restricted" ||
          models.any? { |model| model[:provider_id] == provider && model[:availability_status] == "access_restricted" }
        entry[:readiness] = provider_readiness(entry, paused, models.count { |model| model[:provider_id] == provider })
      end
      { providers: providers, models: models.uniq { |model| [ model[:provider_id], model[:model_id] ] }, catalogue_updated_at: Time.current.iso8601 }
    end

    def manual_model_rows(config, secrets)
      models = config["models"].is_a?(Hash) ? config["models"] : {}
      rows = models.filter_map do |model_id, metadata|
        next unless metadata.is_a?(Hash)

        { "id" => model_id, "display_name" => metadata["display_name"], "description" => metadata["description"],
          "lifecycle" => metadata["lifecycle"] }.compact
      end
      sanitize_rows(rows, secrets)
    end

    def inference_fingerprint(provider, connection, model_id, key)
      return if model_id.blank?

      selected = ProviderConnection.new(provider: provider, integration: connection, api_key: key, model: model_id)
      ProviderEndpoint.validate_url!(selected.base_url, local: ProviderRegistry.definition(provider)[:local], resolve: false)
      selected.inference_fingerprint
    rescue ProviderError
      nil
    end

    def legacy_inference_current?(provider, connection, config, key)
      stored = config["last_inference_configuration_fingerprint"]
      return true if stored.blank?

      inference_fingerprint(provider, connection, config["last_inference_model_id"], key) == stored
    end

    def inference_verification(config, model_id, fingerprint)
      value = config.fetch("inference_verifications", {})[model_id]
      return {} unless value.is_a?(Hash) && fingerprint
      return value if value["configuration_fingerprint"].blank? || value["configuration_fingerprint"] == fingerprint

      {}
    end

    def inference_clock(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def inference_success_recent?(config)
      succeeded = inference_clock(config["last_inference_succeeded_at"])
      return false unless succeeded

      attempt = inference_clock(config["last_inference_attempt_at"])
      attempt.nil? || attempt <= succeeded
    end

    def inference_credit_blocked?(config)
      return false unless config["last_inference_error_code"] == "provider_credit_insufficient"

      succeeded = inference_clock(config["last_inference_succeeded_at"])
      attempt = inference_clock(config["last_inference_attempt_at"])
      succeeded.nil? || attempt.nil? || attempt > succeeded
    end

    def inference_status_for(config, model_id, fingerprint:, legacy_current:, provider_error: nil)
      return "failed" if AUTHENTICATION_ERRORS.include?(provider_error)

      verification = inference_verification(config, model_id, fingerprint)
      if verification["succeeded_at"].present?
        attempt = inference_clock(verification["attempt_at"])
        succeeded = inference_clock(verification["succeeded_at"])
        return "verified" if succeeded && (attempt.nil? || attempt <= succeeded)
      end
      return "billing_blocked" if verification["error_code"] == "provider_credit_insufficient"
      return "failed" if verification["error_code"].present?
      return "billing_blocked" if legacy_current && inference_credit_blocked?(config)
      return "verified" if legacy_current && inference_success_recent?(config) && config["last_inference_model_id"] == model_id

      "unverified"
    end

    def provider_readiness(entry, paused, model_count)
      return "disabled" if paused
      return "unavailable" if AUTHENTICATION_ERRORS.include?(entry[:error_code])
      return "configuration_invalid" if %w[configuration_invalid endpoint_invalid endpoint_forbidden unknown_provider].include?(entry[:error_code])
      return "access_restricted" if entry[:access_restricted]
      return "billing_blocked" if entry[:billing_blocked]
      return "inference_ready" if entry[:inference_ready]
      return "catalogue_available" if entry[:connection_status] == "connected" && model_count.positive? &&
        !ProviderRegistry.manual_only?(entry[:provider_id])
      return "connected" if entry[:connection_status] == "connected"

      "unavailable"
    end

    def discover_provider(provider, key, connection = nil)
      return discover_anthropic(key) if provider == "anthropic"
      return discover_gemini(key) if provider == "google"

      selected = ProviderConnection.new(provider: provider, integration: connection, api_key: key, model: "discovery")
      data = fetch_json(selected, "models")
      raise Error.new("invalid_provider_response", "Invalid model catalogue.") unless data["data"].is_a?(Array)

      rows = data["data"].map do |row|
        normalized = normalize_openai_row(row, provider)
        normalized["context_window"] ||= row.dig("meta", "n_ctx") if provider == "bonsai"
        normalized
      end
      return rows unless provider == "bonsai"

      rows.first(1).map do |row|
        { "id" => selected.model == "discovery" ? bonsai_model : selected.model,
          "display_name" => bonsai_model, "context_window" => row["context_window"] }
      end
    end

    def discover_anthropic(key)
      selected = ProviderConnection.new(provider: "anthropic", model: "discovery")
      rows = []
      cursor = nil
      MAX_PAGES.times do
        query = { limit: 100 }
        query[:after_id] = cursor if cursor
        data = fetch_json(selected, "models", query: query,
          headers: { "x-api-key" => key.to_s, "anthropic-version" => "2023-06-01" })
        raise Error.new("invalid_provider_response", "Invalid model catalogue.") unless data["data"].is_a?(Array)

        rows.concat(data["data"].map { |row| normalize_anthropic(row) })
        return rows unless data["has_more"] == true

        next_cursor = data["last_id"]
        raise Error.new("invalid_provider_response", "Invalid catalogue pagination.") if next_cursor.blank? || next_cursor == cursor

        cursor = next_cursor
      end
      raise Error.new("catalogue_page_limit", "Model catalogue exceeds the discovery limit.")
    end

    def discover_gemini(key)
      selected = ProviderConnection.new(provider: "google", api_key: key, model: "discovery",
        base_url: "https://generativelanguage.googleapis.com/v1beta")
      rows = []
      page_token = nil
      MAX_PAGES.times do
        query = { pageSize: 100 }
        query[:pageToken] = page_token if page_token
        data = fetch_json(selected, "models", query: query,
          headers: { "x-goog-api-key" => key.to_s, "Authorization" => nil })
        raise Error.new("invalid_provider_response", "Invalid model catalogue.") unless data["models"].is_a?(Array)

        rows.concat(data["models"].map { |row| normalize_gemini(row) })
        return rows unless data["nextPageToken"].present?

        page_token = data["nextPageToken"]
      end
      raise Error.new("catalogue_page_limit", "Model catalogue exceeds the discovery limit.")
    end

    def normalize_openai_row(row, provider)
      return row unless row.is_a?(Hash)

      normalized = row.slice("id", "display_name", "description", "lifecycle", *CAPABILITIES,
        "context_window", "max_output_tokens", "supported_parameters", "free_tier", "zero_priced", "rate_limits", "access_restricted")
      normalized["max_output_tokens"] ||= row["max_completion_tokens"]
      normalized["zero_priced"] = zero_token_pricing(row) if row.key?("pricing")
      if provider == "opencode" && opencode_externally_restricted?(row)
        normalized["access_restricted"] = true
      end
      if provider == "openrouter"
        normalized["context_window"] ||= row.dig("top_provider", "context_length")
        normalized["max_output_tokens"] ||= row.dig("top_provider", "max_completion_tokens")
        parameters = Array(row["supported_parameters"]).map(&:to_s)
        normalized["supported_parameters"] = parameters if parameters.any?
        normalized["supports_tools"] = true if parameters.include?("tools")
        normalized["supports_vision"] = true if Array(row.dig("architecture", "input_modalities")).include?("image")
      end
      normalized
    end

    def zero_token_pricing(row)
      pricing = row["pricing"]
      return unless pricing.is_a?(Hash)

      prompt = pricing.values_at("prompt", "input", "prompt_per_token").reject(&:nil?)
      completion = pricing.values_at("completion", "output", "completion_per_token").reject(&:nil?)
      return if prompt.empty? || completion.empty?

      prices = (prompt + completion).map { |value| token_price(value) }
      return if prices.any?(&:nil?)

      prices.all?(&:zero?)
    end

    def token_price(value)
      return value if value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
      return unless value.is_a?(String) && value.bytesize <= 64

      price = Float(value)
      price if price.finite?
    rescue ArgumentError, TypeError
      nil
    end

    def opencode_externally_restricted?(row)
      model_id = row["id"].to_s
      return false if row["provider"] == "opencode-go" || model_id.start_with?("opencode-go/")
      return true if OPENCODE_FREE_CHAT_MODELS.include?(model_id)

      pricing = row["pricing"]
      pricing.is_a?(Hash) && %w[prompt input prompt_per_token].any? do |name|
        price = pricing[name]
        price.present? && Float(price).zero?
      rescue ArgumentError, TypeError
        false
      end
    end

    def normalize_anthropic(row)
      return row unless row.is_a?(Hash)

      normalized = row.slice("id", "display_name", "description", "lifecycle", *CAPABILITIES)
      normalized["context_window"] = row["max_input_tokens"] || row["context_window"]
      normalized["max_output_tokens"] = row["max_tokens"] || row["max_output_tokens"]
      normalized["supports_vision"] = row.dig("capabilities", "image_input", "supported") if row["capabilities"].is_a?(Hash)
      normalized
    end

    def normalize_gemini(row)
      return row unless row.is_a?(Hash)

      normalized = row.slice("displayName", "description", "inputTokenLimit", "outputTokenLimit")
      normalized["id"] = row["name"].to_s.delete_prefix("models/")
      normalized["display_name"] = normalized.delete("displayName")
      normalized["context_window"] = normalized.delete("inputTokenLimit")
      normalized["max_output_tokens"] = normalized.delete("outputTokenLimit")
      normalized
    end

    def bonsai_model
      ENV.fetch("BONSAI_MODEL", "bonsai-2-27b")
    end

    def fetch_json(connection, path, query: {}, headers: {})
      response = SecureHttp.get(connection, path, query: query, headers: headers)
      status = response.code.to_i
      if status == 401
        raise Error.new("invalid_credentials", "Provider model discovery failed.")
      elsif status == 403
        raise Error.new("provider_access_restricted", "Provider access is restricted.", retryable: false)
      elsif !status.between?(200, 299)
        failure = ProviderError.from_http(status, response.body)
        raise Error.new(failure.code, "Provider model discovery failed.", retryable: failure.retryable?)
      end
      data = JSON.parse(response.body)
      raise Error.new("invalid_provider_response", "Invalid model catalogue.") unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error.new("invalid_provider_response", "Invalid model catalogue.")
    rescue ProviderError => e
      raise Error.new(e.code, "Provider model discovery failed.", retryable: e.retryable?)
    end
  end
end
