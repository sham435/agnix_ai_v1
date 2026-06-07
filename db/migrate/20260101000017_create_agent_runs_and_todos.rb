class CreateAgentRunsAndTodos < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :mode, :string, default: "auto_plan", null: false
    create_table :agent_runs, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.string :mode, null: false, default: "auto_plan"
      t.string :status, null: false, default: "planning"
      t.jsonb :plan, default: [], null: false
      t.integer :current_step
      t.timestamps
    end
    add_index :agent_runs, [:conversation_id, :status]

    create_table :agent_todos, id: :uuid do |t|
      t.references :agent_run, type: :uuid, null: false, foreign_key: true
      t.string :title, null: false
      t.string :status, null: false, default: "pending"
      t.text :result
      t.integer :position, null: false
      t.timestamps
    end
    add_index :agent_todos, [:agent_run_id, :position]
  end
end
