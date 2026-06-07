# == Schema Information
#
# Table name: usage_events
#
#  id              :uuid             not null, primary key
#  organization_id :uuid             not null
#  run_id          :uuid
#  event_type      :string           not null
#  tokens          :integer          default(0)
#  cost_cents      :integer          default(0)
#  metadata        :jsonb            default({})
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class UsageEvent < ApplicationRecord
  EVENT_TYPES = %w[chat_completion embedding tool_call file_upload].freeze

  belongs_to :organization
  belongs_to :run, optional: true

  validates :event_type, presence: true

  scope :today, -> { where(created_at: Time.current.all_day) }
  scope :by_type, ->(type) { where(event_type: type) }

  # Bulk insert from jobs.
  def self.track_batch!(rows)
    insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) })
  end
end
