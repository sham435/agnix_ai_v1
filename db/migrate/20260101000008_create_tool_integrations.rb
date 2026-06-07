class CreateToolIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :tool_integrations, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :name, null: false
      t.jsonb :credentials, null: false
      t.jsonb :config, null: false, default: {}
      t.boolean :is_active, null: false, default: true
      t.datetime :last_used_at
      t.timestamps
    end

    add_index :tool_integrations, [:organization_id, :provider]
    add_index :tool_integrations, :is_active
  end
end
