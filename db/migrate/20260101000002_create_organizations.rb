class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :plan, null: false, default: "free"
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    add_index :organizations, :slug, unique: true
  end
end
