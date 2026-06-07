class AgentRun < ApplicationRecord
  belongs_to :conversation
  has_many :todos, class_name: "AgentTodo", dependent: :destroy

  MODES = %w[manual_build auto_build manual_plan auto_plan].freeze
  STATUSES = %w[planning executing completed interrupted].freeze

  validates :mode, inclusion: { in: MODES }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[planning executing]) }

  def auto?
    mode.in?(%w[auto_build auto_plan])
  end

  def plan_first?
    mode.in?(%w[manual_plan auto_plan])
  end

  def build?
    mode.in?(%w[manual_build auto_build])
  end

  def append_reasoning(step, detail = nil)
    steps = (reasoning_steps || [])
    steps << { t: Time.current.iso8601, step: step, detail: detail }
    update!(reasoning_steps: steps)
    broadcast_reasoning
  end

  def broadcast_reasoning
    Turbo::StreamsChannel.broadcast_replace_to(
      conversation,
      target: "reasoning-#{id}",
      partial: "agent_runs/reasoning",
      locals: { run: self }
    )
  end

  after_update_commit :broadcast_status, if: :saved_change_to_status?

  def broadcast_status
    Turbo::StreamsChannel.broadcast_replace_to(
      conversation,
      target: "run-status-#{id}",
      partial: "agent_runs/status_badge",
      locals: { run: self }
    )
  end
end
