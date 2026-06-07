class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :agent, type: :uuid, null: false, foreign_key: true
      t.string :title
      t.string :status, null: false, default: "active"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :conversations, :status
  end
end
