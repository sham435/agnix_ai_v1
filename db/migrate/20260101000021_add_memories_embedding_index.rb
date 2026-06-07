class AddMemoriesEmbeddingIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    count = connection.select_value("SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL").to_i
    if count > 0
      lists = [100, Math.sqrt(count).ceil].max
      execute <<-SQL.squish
        CREATE INDEX CONCURRENTLY IF NOT EXISTS index_memories_on_embedding_cosine
        ON memories USING ivfflat (embedding vector_cosine_ops)
        WITH (lists = #{lists});
      SQL
    else
      Rails.logger.info "Skipping IVFFlat index: no memories with non-null embedding"
    end
  end

  def down
    execute "DROP INDEX IF EXISTS index_memories_on_embedding_cosine"
  end
end
