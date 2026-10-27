# LLM Client - Unified interface for multiple LLM providers.
# Supports Anthropic Claude, OpenAI, Google (Gemini, through its
# OpenAI-compatible endpoint), Ollama (local), and Bonsai (local,
# PrismML's compressed Qwen served by llama.cpp behind an OpenAI-compatible
# API: 1-bit Bonsai 27B and ternary Bonsai 2 27B, each on its own port).
# Sources:
#   - https://docs.anthropic.com/en/api/messages
#   - https://platform.openai.com/docs/api-reference/chat
#   - https://ai.google.dev/gemini-api/docs/openai
#   - https://github.com/ollama/ollama/blob/main/docs/api.md
#   - https://huggingface.co/prism-ml/Bonsai-27B-gguf
#   - https://huggingface.co/collections/prism-ml/bonsai-2
module Llm
  class Client
    attr_reader :provider, :model, :temperature, :max_tokens, :api_key, :top_p

    def initialize(provider:, model:, temperature: 0.7, max_tokens: 4096, api_key: nil, top_p: nil)
      @provider = provider.to_s
      @model = model
      @temperature = temperature
      @max_tokens = max_tokens
      @api_key = api_key
      @top_p = top_p
    end

    # Send a chat completion request.
    # Returns: { content: String, tokens: Integer, finish_reason: String }
    def chat(messages:, tools: [], stream: false)
      adapter.send(:chat,
        messages: messages,
        tools: tools,
        temperature: temperature,
        max_tokens: max_tokens,
        top_p: top_p,
        stream: stream
      )
    end

    # Streaming chat via Action Cable.
    # Yields chunks as they arrive.
    def stream_chat(messages:, tools: [], &block)
      adapter.send(:stream_chat,
        messages: messages,
        tools: tools,
        temperature: temperature,
        max_tokens: max_tokens,
        top_p: top_p,
        &block
      )
    end

    # Generate embeddings for a text string.
    def embeddings(text)
      adapter.send(:embeddings, text)
    end

    # Estimate token count for a message (rough approximation).
    def estimate_tokens(text)
      # ~4 chars per token for English.
      (text.to_s.length / 4.0).ceil
    end

    private

    def adapter
      case provider
      when "anthropic"
        Llm::AnthropicAdapter.new(api_key: api_key, model: model)
      when "openai"
        if api_key.to_s.start_with?("sk-or-v1")
          Llm::OpenaiAdapter.new(
            api_key: api_key,
            model: model,
            base_url: ENV.fetch("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
          )
        else
          Llm::OpenaiAdapter.new(api_key: api_key, model: model)
        end
      when "ollama"
        Llm::OllamaAdapter.new(api_key: api_key, model: model)
      when "bonsai"
        Llm::OpenaiAdapter.new(
          api_key: api_key,
          model: bonsai_model,
          base_url: bonsai_base_url,
          top_p: top_p
        )
      when "opencode"
        Llm::OpenaiAdapter.new(
          api_key: api_key,
          model: model,
          base_url: ENV.fetch("OPENCODE_BASE_URL", "https://opencode.ai/zen/v1")
        )
      when "google"
        # Gemini publishes an OpenAI-compatible surface, so the shared adapter
        # speaks it unchanged (Bearer key, /chat/completions, tool_calls). The
        # base URL keeps its /v1 suffix because the adapter appends the path.
        Llm::OpenaiAdapter.new(
          api_key: api_key,
          model: model,
          base_url: google_base_url
        )
      else
        raise ArgumentError, "Unknown LLM provider: #{provider}"
      end
    end

    def google_base_url
      ENV.fetch("GOOGLE_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai/v1")
    end

    # Endpoint selection is driven by the PROVIDER, never by a stored model
    # label. A stale/foreign label (e.g. "claude-sonnet-4-6" left over from an
    # earlier anthropic config) must not silently route to the wrong server.
    #   bonsai-27b   - 1-bit Bonsai 27B (tutorial, ~3.9 GB)   -> :8910 (legacy)
    #   everything else under provider "bonsai" defaults to the primary
    #   ternary Bonsai 2 27B server on :8080.
    def bonsai_base_url
      if model.to_s == "bonsai-27b"
        ENV.fetch("BONSAI_BASE_URL", "http://127.0.0.1:8910/v1")
      else
        ENV.fetch("BONSAI2_BASE_URL", "http://127.0.0.1:8080/v1")
      end
    end

    # Canonical model id sent to the local server. The llama.cpp server accepts
    # any alias, but sending a coherent id keeps logs/telemetry honest. Normalize
    # obsolete or foreign labels to the configured Bonsai model; preserve the
    # explicit 1-bit id so that endpoint stays reachable.
    def bonsai_model
      return model.to_s if model.to_s == "bonsai-27b"

      ENV.fetch("BONSAI_MODEL", "bonsai-2-27b")
    end
  end
end
