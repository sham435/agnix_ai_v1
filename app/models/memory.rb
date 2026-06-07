# == Schema Information
#
# Table name: memories
#
#  id          :uuid             not null, primary key
#  user_id     :uuid             not null
#  agent_id    :uuid
#  content     :text             not null
#  embedding   :vector(1536)
#  source_type :string
#  source_id   :uuid
#  metadata    :jsonb            default({})
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
class Memory < ApplicationRecord
  belongs_to :user
  belongs_to :agent, optional: true
  belongs_to :source, polymorphic: true, optional: true

  validates :content, presence: true

  # Nearest neighbor search via pgvector cosine distance.
  scope :nearest_to, ->(vector, limit = 5) {
    order(Arel.sql("embedding <=> '#{vector}'")).limit(limit)
  }

  scope :for_user_and_agent, ->(user_id, agent_id) {
    where(user_id: user_id).where(agent_id: [agent_id, nil])
  }

  # Methods.
  def self.search_by_text(query, user_id: nil, agent_id: nil, limit: 10)
    scope = self
    scope = scope.where(user_id: user_id) if user_id
    scope = scope.where(agent_id: agent_id) if agent_id

    # Try semantic search first if embeddings exist.
    embedding = EmbeddingService.generate(query)
    if embedding
      return scope.nearest_to(embedding, limit: limit)
    end

    # Fallback to full-text search.
    scope.where("to_tsvector('english', content) @@ plainto_tsquery('english', ?)", query)
      .limit(limit)
  end

  def has_embedding?
    embedding.present?
  end
end
