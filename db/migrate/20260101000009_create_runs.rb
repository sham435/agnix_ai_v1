class CreateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs, id: :uuid do |t|
      t.references :agent, type: :uuid, null: false, foreign_key: true
      t.references :conversation, type: :uuid, foreign_key: true
      t.jsonb :input, null: false, default: {}
      t.jsonb :output
      t.string :status, null: false, default: "pending"
      t.integer :tokens_used, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :runs, :status
    add_index :runs, :started_at
  end
end
