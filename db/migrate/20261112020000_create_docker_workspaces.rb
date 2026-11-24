# frozen_string_literal: true

class CreateDockerWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :conversation, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :runtime, null: false, default: "python3"
      # pending -> the row exists but the manager has not confirmed a container
      # ready   -> the manager reports the execution container running
      # stopped -> the container exists but is not running (daemon restart)
      # failed  -> the manager refused or the daemon was unavailable
      # destroyed
      t.string :state, null: false, default: "pending"
      t.string :last_error
      t.datetime :destroyed_at
      t.timestamps
    end

    add_index :workspaces, [ :user_id, :conversation_id ], unique: true,
              where: "conversation_id IS NOT NULL", name: "index_workspaces_on_user_and_conversation"

    create_table :workspace_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :workspaces }, type: :uuid
      t.string :kind, null: false
      t.jsonb :argv, null: false, default: "[]"
      t.boolean :ok, null: false, default: false
      t.integer :exit_code
      t.boolean :timed_out, null: false, default: false
      t.integer :duration_ms
      t.text :stdout
      t.text :stderr
      t.integer :stdout_bytes, null: false, default: 0
      t.integer :stderr_bytes, null: false, default: 0
      t.timestamps
    end

    add_index :workspace_runs, [ :workspace_id, :kind ]

    create_table :workspace_preview_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :workspaces }, type: :uuid
      t.integer :port, null: false
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.integer :request_count, null: false, default: 0
      t.timestamps
    end

    add_index :workspace_preview_sessions, :token, unique: true
  end
end
