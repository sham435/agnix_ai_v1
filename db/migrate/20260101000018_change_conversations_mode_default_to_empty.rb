class ChangeConversationsModeDefaultToEmpty < ActiveRecord::Migration[8.1]
  def change
    change_column_default :conversations, :mode, from: "auto_plan", to: ""
    execute "UPDATE conversations SET mode = '' WHERE mode = 'auto_plan'"
  end
end
