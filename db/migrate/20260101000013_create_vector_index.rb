class CreateVectorIndex < ActiveRecord::Migration[8.1]
  def up
    # IVFFlat requires at least one row with non-NULL embedding.
    count = connection.select_value(
      "SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL"
    ).to_i
    return if count.zero?

    execute <<-SQL.squish
      CREATE INDEX memories_embedding_idx ON memories
      USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100);
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS memories_embedding_idx"
  end
end
