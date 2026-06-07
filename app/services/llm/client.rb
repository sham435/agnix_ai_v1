# LLM Client - Unified interface for multiple LLM providers.
# Supports Anthropic Claude, OpenAI, and Ollama (local).
# Sources:
#   - https://docs.anthropic.com/en/api/messages
#   - https://platform.openai.com/docs/api-reference/chat
#   - https://github.com/ollama/ollama/blob/main/docs/api.md
module Llm
  class Client
    attr_reader :provider, :model, :temperature, :max_tokens, :api_key

    def initialize(provider:, model:, temperature: 0.7, max_tokens: 4096, api_key: nil)
      @provider = provider.to_s
      @model = model
      @temperature = temperature
      @max_tokens = max_tokens
      @api_key = api_key
    end

    # Send a chat completion request.
    # Returns: { content: String, tokens: Integer, finish_reason: String }
    def chat(messages:, tools: [], stream: false)
      adapter.send(:chat,
        messages: messages,
        tools: tools,
        temperature: temperature,
        max_tokens: max_tokens,
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
        Llm::OpenaiAdapter.new(api_key: api_key, model: model)
      when "ollama"
        Llm::OllamaAdapter.new(api_key: api_key, model: model)
      when "opencode"
        Llm::OpenaiAdapter.new(
          api_key: api_key,
          model: model,
          base_url: ENV.fetch("OPENCODE_BASE_URL", "https://opencode.ai/zen/v1")
        )
      else
        raise ArgumentError, "Unknown LLM provider: #{provider}"
      end
    end
  end
end
