# Embedding Job - Generates embeddings for a Memory record.
class EmbeddingJob < ApplicationJob
  queue_as :embeddings
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(memory_id)
    memory = Memory.find(memory_id)
    return if memory.has_embedding?

    EmbeddingService.embed_memory(memory)
  rescue => e
    Rails.logger.error "Embedding job failed for Memory #{memory_id}: #{e.message}"
    raise
  end
end
