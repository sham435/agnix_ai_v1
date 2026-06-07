class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.text :system_prompt
      t.string :model, null: false, default: "claude-sonnet-4-6"
      t.string :provider, null: false, default: "anthropic"
      t.jsonb :tools, null: false, default: []
      t.jsonb :config, null: false, default: {}
      t.boolean :is_active, null: false, default: true
      t.timestamps
    end

    add_index :agents, [:organization_id, :slug], unique: true
    add_index :agents, :is_active
  end
end
