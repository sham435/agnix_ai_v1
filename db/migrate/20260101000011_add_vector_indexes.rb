class AddVectorIndexes < ActiveRecord::Migration[8.1]
  def up
    # IVFFlat requires at least one row with non-NULL embedding.
    # Skip silently if table is empty.
    count = connection.select_value(
      "SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL"
    ).to_i
    return if count.zero?

    execute <<-SQL.squish
      CREATE INDEX memories_embedding_idx ON memories
      USING ivfflat (embedding vector_cosine_ops)
      WITH (lists = 100);
    SQL
  rescue PG::InvalidParameterValue
    # Table has no embedding data; index cannot be created yet.
    Rails.logger.info "Skipping IVF index: memories table has no embedding data"
  end

  def down
    execute "DROP INDEX IF EXISTS memories_embedding_idx"
  end
end
