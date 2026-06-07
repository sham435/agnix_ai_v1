class AddReasoningToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :reasoning_steps, :jsonb, default: []
  end
end
