class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.string :role, null: false, default: "member"
      t.timestamps
    end

    add_index :memberships, [:user_id, :organization_id], unique: true
  end
end
