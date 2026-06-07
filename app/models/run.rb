# == Schema Information
#
# Table name: runs
#
#  id              :uuid             not null, primary key
#  agent_id        :uuid             not null
#  conversation_id :uuid
#  input           :jsonb            not null
#  output          :jsonb
#  status          :string           default("pending"), not null
#  tokens_used     :integer          default(0)
#  started_at      :datetime
#  finished_at     :datetime
#  error_message   :text
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Run < ApplicationRecord
  belongs_to :agent, counter_cache: true
  belongs_to :conversation, optional: true, touch: true

  has_many :usage_events, dependent: :nullify

  enum :status, { pending: "pending", running: "running", succeeded: "succeeded", failed: "failed", cancelled: "cancelled" }, default: :pending

  validates :status, presence: true

  scope :active, -> { where(status: %w[pending running]) }
  scope :recent, -> { order(started_at: :desc) }

  # Methods.
  def finish!(output:, tokens_used:)
    update!(status: :succeeded, output: output, tokens_used: tokens_used, finished_at: Time.current)
  end

  def fail!(error)
    update!(
      status: :failed,
      error_message: error.to_s,
      finished_at: Time.current
    )
  end

  def cancel!
    update!(status: :cancelled, finished_at: Time.current)
  end

  def duration_seconds
    return nil unless started_at && finished_at
    (finished_at - started_at).to_i
  end

  def running?
    status == "running"
  end

  def completed?
    status == "succeeded"
  end

  def failed?
    status == "failed"
  end
end
