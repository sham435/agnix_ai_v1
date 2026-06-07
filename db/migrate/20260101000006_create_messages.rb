class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content
      t.integer :tokens
      t.jsonb :tool_calls, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :messages, :role
    add_index :messages, :created_at
  end
end
