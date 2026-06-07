class AddProjectAndExternalIdToMessages < ActiveRecord::Migration[8.1]
  def change
    # Add project reference to conversations.
    add_reference :conversations, :project, type: :uuid, foreign_key: true

    # Add external_id and project_id to messages.
    add_column :messages, :external_id, :string
    add_index :messages, :external_id, where: "external_id IS NOT NULL"

    # Track WhatsApp delivery receipts.
    add_column :messages, :delivery_status, :string, default: "pending"
    add_column :messages, :delivered_at, :datetime
    add_column :messages, :read_at, :datetime
  end
end
