# frozen_string_literal: true

module Llm
  class Client
    attr_reader :provider, :model, :temperature, :max_tokens, :api_key, :top_p, :connection, :model_config

    def initialize(provider:, model:, temperature: 0.7, max_tokens: 4096, api_key: nil, top_p: nil,
                   connection: nil, model_config: nil)
      @provider = provider.to_s
      @model = model
      @temperature = temperature
      @max_tokens = max_tokens
      @api_key = connection ? connection.api_key : api_key
      @top_p = top_p
      @connection = connection
      @model_config = model_config
    end

    def chat(messages:, tools: [], stream: false, max_tokens: nil, &block)
      stream = false unless streaming_supported?
      adapter.send(:chat, messages: messages, tools: tools, temperature: temperature,
                   max_tokens: max_tokens || self.max_tokens, top_p: top_p, stream: stream, &block)
    end

    def inference_model
      provider == "bonsai" ? bonsai_model : model
    end

    def streaming_supported?
      effective_connection.supports?("supports_streaming") != false
    end

    def stream_chat(messages:, tools: [], max_tokens: nil, &block)
      unless streaming_supported?
        raise ProviderError.new("Streaming is not available for this model.", code: "streaming_unavailable")
      end

      adapter.send(:stream_chat, messages: messages, tools: tools, temperature: temperature,
                   max_tokens: max_tokens || self.max_tokens, top_p: top_p, &block)
    end

    def embeddings(text)
      adapter.send(:embeddings, text)
    end

    def estimate_tokens(text)
      (text.to_s.length / 4.0).ceil
    end

    private

    def adapter
      @adapter ||= case provider
      when "anthropic"
                     Llm::AnthropicAdapter.new(api_key: resolved_api_key, model: model,
                       connection: effective_connection)
      when "ollama"
                     Llm::OllamaAdapter.new(api_key: resolved_api_key, model: model)
      else
                     openai_compatible_adapter
      end
    end

    def openai_compatible_adapter
      selected_connection = effective_connection
      adapter_class = selected_connection.api_family == "responses" ? Llm::ResponsesAdapter : Llm::OpenaiAdapter
      kwargs = { api_key: selected_connection.api_key, model: adapter_model,
                 base_url: adapter_base_url(selected_connection), top_p: top_p,
                 connection: selected_connection }
      kwargs[:chat_template_kwargs] = { "enable_thinking" => false } if provider == "bonsai"
      adapter_class.new(**kwargs)
    end

    def effective_connection
      return connection if connection && (connection.provider == provider || legacy_openrouter_connection?)
      raise ProviderError.new("The provider connection does not match the selected provider.", code: "configuration_invalid") if connection

      base_url = legacy_openrouter? ? openrouter_base_url : nil
      ProviderConnection.new(provider: legacy_openrouter? ? "openrouter" : provider,
        api_key: resolved_api_key, model: adapter_model, base_url: base_url, model_config: model_config)
    end

    def resolved_api_key
      return connection.api_key if connection

      api_key.presence || ProviderRegistry.environment_key(provider) || ProviderRegistry.credentials_key(provider) ||
        (provider == "openai" ? ENV["OPENROUTER_API_KEY"].to_s.strip.presence : nil) ||
        ProviderRegistry.default_api_key(provider)
    end

    def legacy_openrouter?
      ProviderConnection.resolve_provider(provider, resolved_api_key) == "openrouter" && provider == "openai"
    end

    def legacy_openrouter_connection?
      provider == "openai" && connection&.provider == "openrouter" &&
        ProviderConnection.resolve_provider(provider, connection.api_key) == "openrouter"
    end

    def adapter_model
      inference_model
    end

    def adapter_base_url(selected_connection)
      return if provider == "openai" && !legacy_openrouter? && selected_connection.config["base_url"].blank?

      selected_connection.base_url
    end

    def google_base_url
      ENV.fetch("GOOGLE_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/v1")
    end

    def openrouter_base_url
      ENV.fetch("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    end

    def bonsai_base_url
      model.to_s == "bonsai-27b" ? ENV.fetch("BONSAI_BASE_URL", "http://127.0.0.1:8910/v1") :
        ENV.fetch("BONSAI2_BASE_URL", "http://127.0.0.1:8080/v1")
    end

    def bonsai_model
      return model.to_s if model.to_s == "bonsai-27b"

      ENV.fetch("BONSAI_MODEL", "bonsai-2-27b")
    end
  end
end
