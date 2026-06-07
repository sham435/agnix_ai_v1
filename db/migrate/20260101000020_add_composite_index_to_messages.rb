class AddCompositeIndexToMessages < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :messages, [:conversation_id, :created_at],
              name: "index_messages_on_conversation_id_and_created_at",
              algorithm: :concurrently
  end
end
