class AddCountersAndVectorIndex < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :messages_count, :integer, default: 0, null: false
    add_column :agents, :runs_count, :integer, default: 0, null: false
    add_column :organizations, :conversations_count, :integer, default: 0, null: false
  end
end
