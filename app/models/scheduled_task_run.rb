# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_task_runs
#
#  id                   :uuid             not null, primary key
#  scheduled_task_id    :uuid             not null
#  conversation_id      :uuid
#  assistant_message_id :uuid
#  status               :string           default("queued"), not null
#  started_at           :datetime
#  finished_at          :datetime
#  error                :text
#  tokens               :integer          default(0), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#
# One execution of a ScheduledTask. State transitions live here (model), not in
# the job, so the DB logic stays out of the service layer.
class ScheduledTaskRun < ApplicationRecord
  belongs_to :scheduled_task
  belongs_to :conversation, optional: true
  belongs_to :assistant_message, class_name: "Message", optional: true, inverse_of: false

  enum :status,
       { queued: "queued", running: "running", succeeded: "succeeded", failed: "failed" },
       default: :queued

  scope :recent, -> { order(created_at: :desc) }

  def mark_running!
    update!(status: :running, started_at: started_at || Time.current)
  end

  def mark_succeeded!(assistant_message: nil, tokens: 0)
    update!(
      status: :succeeded,
      assistant_message: assistant_message,
      conversation: assistant_message&.conversation || conversation,
      tokens: tokens.to_i,
      finished_at: Time.current
    )
  end

  def mark_failed!(error_message)
    update!(status: :failed, error: error_message.to_s.truncate(1000), finished_at: Time.current)
  end
end
