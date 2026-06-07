class CreateAutoFixAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :auto_fix_attempts, id: :uuid do |t|
      t.string :issue_id, null: false
      t.integer :iteration, null: false
      t.string :status, null: false
      t.integer :tokens_used
      t.integer :duration_ms
      t.text :stderr
      t.text :patch
      t.jsonb :files_modified, default: []
      t.timestamps
    end
    add_index :auto_fix_attempts, :issue_id
  end
end
