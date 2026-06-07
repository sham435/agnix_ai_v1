class CreateBilling < ActiveRecord::Migration[8.1]
  def change
    # Subscriptions.
    create_table :subscriptions, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.string :stripe_id, null: false
      t.string :stripe_price_id
      t.string :status, null: false, default: "incomplete"
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.datetime :canceled_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :subscriptions, :stripe_id, unique: true

    # Invoices.
    create_table :invoices, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.string :stripe_id, null: false
      t.integer :amount
      t.string :currency, null: false, default: "usd"
      t.string :status, null: false, default: "draft"
      t.string :hosted_invoice_url
      t.string :invoice_pdf
      t.datetime :period_start
      t.datetime :period_end
      t.datetime :paid_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :invoices, :stripe_id, unique: true

    # Usage events for token metering.
    create_table :usage_events, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :run, type: :uuid, foreign_key: true
      t.string :event_type, null: false
      t.integer :tokens, null: false, default: 0
      t.integer :cost_cents, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps null: false
    end

    add_index :usage_events, [:organization_id, :created_at]
    add_index :usage_events, :event_type
  end
end
