# frozen_string_literal: true

module Llm
  module ProviderRegistry
    CHAT_PARAMETERS = %w[
      model messages temperature max_tokens top_p stream stream_options tools tool_choice response_format seed stop
      frequency_penalty presence_penalty logprobs top_logprobs reasoning_effort chat_template_kwargs
      parallel_tool_calls max_completion_tokens
    ].freeze
    RESPONSES_PARAMETERS = %w[
      model input instructions temperature max_output_tokens top_p stream tools tool_choice reasoning text
      parallel_tool_calls store include metadata user service_tier truncation
      response_format stop seed presence_penalty frequency_penalty logprobs top_logprobs
    ].freeze
    CUSTOM_HEADER_ALLOWLIST = %w[
      HTTP-Referer X-Title X-OpenRouter-Title X-OpenRouter-Categories X-Api-Key Api-Key X-Goog-Api-Key
      X-Stainless-Lang X-Stainless-Package-Version X-Stainless-OS X-Stainless-Arch
      X-Stainless-Runtime X-Stainless-Runtime-Version
    ].freeze
    CREDENTIAL_HEADERS = %w[authorization x-api-key api-key x-goog-api-key].freeze
    PROTECTED_HEADERS = %w[authorization content-length host].freeze
    API_FAMILY_LABELS = {
      "chat_completions" => "Chat Completions", "responses" => "Responses", "messages" => "Messages"
    }.freeze

    DEFINITIONS = {
      "anthropic" => {
        name: "Anthropic", base_url: "https://api.anthropic.com/v1", env_key: "ANTHROPIC_API_KEY",
        discovery: "anthropic", api_families: %w[messages], read_timeout: 120
      },
      "openai" => {
        name: "OpenAI", base_url: "https://api.openai.com/v1", env_key: "OPENAI_API_KEY",
        discovery: "openai", api_families: %w[chat_completions responses], read_timeout: 120
      },
      "nvidia_nim" => {
        name: "NVIDIA NIM", base_url: "https://integrate.api.nvidia.com/v1", env_key: "NVIDIA_NIM_API_KEY",
        discovery: "none", manual_only: true, api_families: %w[chat_completions], read_timeout: 120,
        example_model_ids: %w[
          nvidia/nemotron-3.5-lightning-30b-a3b nvidia/nemotron-3.5-bolt-e4b
          deepseek-ai/deepseek-v4-flash meta/llama-3.3-70b-instruct
        ]
      },
      "google" => {
        name: "Google AI Studio", base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        env_key: "GOOGLE_API_KEY", discovery: "gemini", api_families: %w[chat_completions], read_timeout: 120
      },
      "openrouter" => {
        name: "OpenRouter", base_url: "https://openrouter.ai/api/v1", env_key: "OPENROUTER_API_KEY",
        discovery: "openai", api_families: %w[chat_completions responses], read_timeout: 120
      },
      "groq" => {
        name: "Groq", base_url: "https://api.groq.com/openai/v1", env_key: "GROQ_API_KEY",
        discovery: "openai", api_families: %w[chat_completions], read_timeout: 120
      },
      "cerebras" => {
        name: "Cerebras", base_url: "https://api.cerebras.ai/v1", env_key: "CEREBRAS_API_KEY",
        discovery: "openai", api_families: %w[chat_completions], read_timeout: 120
      },
      "opencode" => {
        name: "OpenCode", base_url: "https://opencode.ai/zen/v1", env_key: "OPENCODE_API_KEY",
        discovery: "openai", api_families: %w[chat_completions], read_timeout: 120
      },
      "bonsai" => {
        name: "Bonsai", base_url: nil, env_key: "BONSAI_API_KEY", default_api_key: "local", discovery: "bonsai",
        api_families: %w[chat_completions], read_timeout: 600, local: true
      },
      "ollama" => {
        name: "Ollama", base_url: nil, env_key: nil, discovery: "none",
        api_families: %w[chat_completions], read_timeout: 600, local: true
      }
    }.freeze

    module_function

    def builtin?(provider)
      DEFINITIONS.key?(provider.to_s)
    end

    def custom?(provider)
      provider.to_s.match?(/\Acustom-[a-z0-9][a-z0-9_-]{2,63}\z/)
    end

    def manual_only?(provider)
      definition(provider)[:manual_only] == true
    end

    def definition(provider)
      DEFINITIONS[provider.to_s] || {}
    end

    def name(provider)
      definition(provider)[:name] || provider.to_s.delete_prefix("custom-").tr("-_", " ").titleize
    end

    def env_key(provider)
      definition(provider)[:env_key]
    end

    def example_model_ids(provider)
      Array(definition(provider)[:example_model_ids])
    end

    def environment_key(provider)
      key = env_key(provider)
      key && ENV[key].to_s.strip.presence
    end

    def default_api_key(provider)
      definition(provider)[:default_api_key]
    end

    def credentials_key(provider)
      return unless builtin?(provider)

      Rails.application.credentials.dig(provider.to_sym, :api_key).presence
    end

    def api_families(provider)
      definition(provider)[:api_families] || %w[chat_completions responses]
    end

    def default_api_family(provider)
      return "messages" if provider.to_s == "anthropic"

      api_families(provider).first
    end

    def api_family?(provider, family)
      api_families(provider).include?(family.to_s)
    end

    def supported_parameters(provider, family)
      case family.to_s
      when "responses" then RESPONSES_PARAMETERS
      when "chat_completions" then CHAT_PARAMETERS
      else []
      end
    end

    def api_family_options(provider)
      api_families(provider).map { |family| [ API_FAMILY_LABELS.fetch(family, family.humanize), family ] }
    end

    def credential_header?(name)
      CREDENTIAL_HEADERS.include?(name.to_s.downcase)
    end

    def protected_header?(name)
      PROTECTED_HEADERS.include?(name.to_s.downcase)
    end

    def header_name_allowed?(name)
      CUSTOM_HEADER_ALLOWLIST.any? { |allowed| allowed.casecmp?(name.to_s) }
    end
  end
end
