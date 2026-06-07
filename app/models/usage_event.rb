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
  scope :this_month, -> { where(created_at: Time.current.all_month) }
  scope :by_type, ->(type) { where(event_type: type) }

  def self.total_tokens_this_month(organization_id)
    where(organization_id: organization_id).this_month.sum(:tokens)
  end

  def self.total_cost_this_month(organization_id)
    where(organization_id: organization_id).this_month.sum(:cost_cents)
  end

  # Bulk insert from jobs.
  def self.track_batch!(rows)
    insert_all(rows.map { |r| r.merge(created_at: Time.current, updated_at: Time.current) })
  end
end
