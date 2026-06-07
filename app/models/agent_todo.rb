class AgentTodo < ApplicationRecord
  belongs_to :agent_run

  validates :title, presence: true
  validates :position, presence: true
  validates :status, inclusion: { in: %w[pending in_progress done failed] }
end
