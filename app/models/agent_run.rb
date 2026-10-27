class AgentRun < ApplicationRecord
  belongs_to :conversation
  has_many :todos, class_name: "AgentTodo", dependent: :destroy

  MODES = %w[manual_build auto_build manual_plan auto_plan].freeze
  STATUSES = %w[planning executing completed interrupted failed].freeze

  # Quoted absolute path targets embedded in plan step titles ("Write '/a/b'").
  QUOTED_PATH_PATTERN = /'([^']+)'/.freeze

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

  # Final gate before a run reports completion: every quoted path target that
  # a DONE build step promises must exist on disk when the run finalizes.
  # Steps whose promised outputs are missing are downgraded to failed with an
  # explicit verification note, and the run itself becomes "failed" — a build
  # must not finish as a success while its outputs are absent (e.g.
  # School run 58fea926 completed while only README.md had been written).
  # Interrupted runs are left untouched — interruption is already truthful.
  def verify_outputs!
    return status if status == "interrupted"

    downgraded = 0
    if build?
      todos.where(status: "done").find_each do |todo|
        path = todo.title[QUOTED_PATH_PATTERN, 1]
        next if path.blank? || File.exist?(path.to_s)

        todo.update!(
          status: "failed",
          result: [ todo.result.presence, "Output verification: '#{path}' does not exist on disk after the run." ].compact.join(" — ")
        )
        downgraded += 1
      end

      append_reasoning("Output verification", downgraded.positive? ?
        "#{downgraded} completed step(s) referenced outputs not found on disk; run marked failed." :
        "All target outputs of completed steps exist on disk.")
    end

    if downgraded.positive?
      update!(status: "failed")
    else
      update!(status: "completed")
    end
    status
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
