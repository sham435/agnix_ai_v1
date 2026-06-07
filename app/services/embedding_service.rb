# Embedding Service - Generate and manage vector embeddings for RAG.
# Uses pgvector for storage and similarity search.
# Sources:
#   - https://github.com/pgvector/pgvector
#   - https://danubedata.ro/blog/pgvector-rag-managed-postgres-2026
#   - https://docs.railway.com/guides/rag-pipeline-pgvector
class EmbeddingService
  # Generate an embedding for a text string.
  # Returns an array of floats (1536 dimensions for OpenAI text-embedding-3-small).
  def self.generate(text, provider: "openai")
    return nil if text.blank?

    case provider
    when "openai"
      generate_openai(text)
    when "ollama"
      generate_ollama(text)
    else
      raise ArgumentError, "Unknown embedding provider: #{provider}"
    end
  end

  # Generate and store embeddings for a Memory record.
  def self.embed_memory(memory, provider: "openai")
    embedding = generate(memory.content, provider: provider)
    return false unless embedding

    memory.update!(embedding: embedding)
    true
  end

  # Generate embeddings for bulk texts.
  def self.bulk_generate(texts, provider: "openai")
    texts.map { |text| generate(text, provider: provider) }.compact
  end

  # Search for similar memories.
  def self.search(query, user_id: nil, agent_id: nil, limit: 10)
    Memory.search_by_text(query, user_id: user_id, agent_id: agent_id, limit: limit)
  end

  class << self
    private

    def generate_openai(text)
      api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV.fetch("OPENAI_API_KEY", "")
      return nil if api_key.blank?

      client = Llm::OpenaiAdapter.new(api_key: api_key, model: "text-embedding-3-small")
      client.embeddings(text)
    rescue => e
      Rails.logger.error "OpenAI embedding error: #{e.message}"
      nil
    end

    def generate_ollama(text)
      client = Llm::OllamaAdapter.new(api_key: nil, model: ENV.fetch("OLLAMA_EMBED_MODEL", "nomic-embed-text"))
      client.embeddings(text)
    rescue => e
      Rails.logger.error "Ollama embedding error: #{e.message}"
      nil
    end
  end
end
