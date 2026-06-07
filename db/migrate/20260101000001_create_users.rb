class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :name
      t.string :role, null: false, default: "user"
      t.string :stripe_customer_id
      t.string :whatsapp_phone
      t.jsonb :settings, null: false, default: {}
      t.string :remember_token
      t.datetime :confirmed_at
      t.datetime :last_login_at
      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :remember_token, unique: true
    add_index :users, :whatsapp_phone, unique: true, where: "whatsapp_phone IS NOT NULL"
  end
end
