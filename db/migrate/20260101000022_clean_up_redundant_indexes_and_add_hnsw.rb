# Remove redundant indexes, add HNSW pgvector index for production scale,
# and clean up duplicate index on project_links.
#
# Why:
# - index_messages_on_conversation_id is fully covered by
#   index_messages_on_conversation_id_and_created_at (leftmost prefix).
# - index_memories_on_agent_id is covered by index_memories_on_user_id_and_agent_id
#   for the agent-only case (single-column is still useful but not needed
#   since for_user_and_agent scope always filters by user_id first).
# - project_links has TWO indexes on project_id (duplicate).
# - HNSW provides better recall for large memory sets vs IVFFlat and
#   doesn't require rebuilding as data grows.
class CleanUpRedundantIndexesAndAddHnsw < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Drop redundant messages index (covered by composite).
    remove_index :messages,
                 column: [:conversation_id],
                 name: "index_messages_on_conversation_id",
                 if_exists: true,
                 algorithm: :concurrently

    # Drop redundant memories index (covered by compound).
    remove_index :memories,
                 column: [:agent_id],
                 name: "index_memories_on_agent_id",
                 if_exists: true,
                 algorithm: :concurrently

    # Drop duplicate project_links index (keep the Rails-named one).
    remove_index :project_links,
                 column: [:project_id],
                 name: "idx_project_links_on_project_id",
                 if_exists: true,
                 algorithm: :concurrently

    # Add HNSW index for cosine similarity on memories.embedding.
    # HNSW works on empty tables and doesn't require periodic rebuilds.
    # m=16, ef_construction=64 are the pgvector defaults for good recall.
    # Skip if column has no dimension set (atttypmod = -1) — IVFFlat will be used instead.
    has_dimension = connection.select_value(<<~SQL.squish).to_i > 0
      SELECT 1 FROM pg_attribute
      WHERE attrelid = 'memories'::regclass
        AND attname = 'embedding'
        AND atttypmod > 0;
    SQL

    if has_dimension
      reversible do |dir|
        dir.up do
          execute <<-SQL.squish
            CREATE INDEX CONCURRENTLY IF NOT EXISTS index_memories_on_embedding_hnsw
            ON memories USING hnsw (embedding vector_cosine_ops)
            WITH (m = 16, ef_construction = 64);
          SQL
        end
        dir.down do
          execute "DROP INDEX IF EXISTS index_memories_on_embedding_hnsw"
        end
      end
    else
      Rails.logger.info "Skipping HNSW index: memories.embedding has no dimension set"
    end
  end
end
