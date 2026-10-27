# Embedding Job - Generates embeddings for a Memory record.
class EmbeddingJob < ApplicationJob
  queue_as :embeddings
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(memory_id)
    memory = Memory.find(memory_id)

    # Reload to avoid race with concurrent EmbeddingJob on same record.
    memory.reload
    return if memory.has_embedding?

    EmbeddingService.embed_memory(memory)
  rescue ActiveRecord::RecordNotFound
    Rails.logger.info "EmbeddingJob: Memory #{memory_id} deleted, skipping"
  rescue => e
    Rails.logger.error "Embedding job failed for Memory #{memory_id}: #{e.message}"
    raise
  end
end
