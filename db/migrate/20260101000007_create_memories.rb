class CreateMemories < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector" unless extension_enabled?("vector")

    create_table :memories, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, foreign_key: true
      t.text :content, null: false
      t.column :embedding, :vector, limit: 1536
      t.string :source_type
      t.uuid :source_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :memories, [:user_id, :agent_id]
    add_index :memories, [:source_type, :source_id]
  end
end
