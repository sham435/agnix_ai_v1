# frozen_string_literal: true

# == Schema Information
#
# Table name: scheduled_tasks
#
#  id              :uuid             not null, primary key
#  user_id         :uuid             not null
#  organization_id :uuid             not null
#  agent_id        :uuid             not null
#  conversation_id :uuid
#  name            :string           not null
#  prompt          :text             not null
#  schedule_type   :string           not null
#  cron            :string
#  run_at          :datetime
#  timezone        :string           not null
#  status          :string           default("active"), not null
#  next_run_at     :datetime
#  last_run_at     :datetime
#  run_count       :integer          default(0), not null
#  max_runs        :integer
#  expires_at      :datetime
#  metadata        :jsonb            default({}), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# A ChatGPT-style automation: a prompt that fires on a cron or a one-time
# schedule and lands its answer in a conversation. All scheduling math lives
# here (never in jobs/controllers/views) — see compute_next_run_at!.
class ScheduledTask < ApplicationRecord
  # Consecutive RunJob failures after which an otherwise-active recurring task
  # is flipped to :failed (recorded in metadata["consecutive_failures"]).
  MAX_CONSECUTIVE_FAILURES = 3

  DEFAULT_TIMEZONE = "UTC"

  belongs_to :user
  belongs_to :organization
  belongs_to :agent
  belongs_to :conversation, optional: true

  has_many :scheduled_task_runs, dependent: :destroy

  enum :schedule_type, { recurring: "recurring", one_time: "one_time" }
  enum :status,
       { active: "active", paused: "paused", completed: "completed",
         failed: "failed", cancelled: "cancelled" },
       default: :active

  # Wall-clock input for a one-time schedule. The datetime picker sends a naive
  # local string; we interpret it in the task's own timezone and store UTC.
  attr_writer :run_at_wall
  def run_at_wall
    @run_at_wall ||= run_at&.in_time_zone(timezone.presence || DEFAULT_TIMEZONE)&.strftime("%Y-%m-%dT%H:%M")
  end

  validates :name, :prompt, presence: true
  validates :timezone, presence: true
  validate :timezone_is_valid
  validates :schedule_type, inclusion: { in: schedule_types.keys }
  validate :schedule_is_well_formed
  validates :max_runs, numericality: { only_integer: true, greater_than_or_equal_to: 1 }, allow_nil: true

  normalizes :timezone, with: ->(z) { z.to_s.strip }
  normalizes :cron, with: ->(c) { c.to_s.strip.presence }

  before_validation :apply_run_at_wall
  before_save :materialize_next_run_at, if: -> { will_schedule_next_run? }

  scope :due, ->(t = Time.current) { where(status: :active).where.not(next_run_at: nil).where(next_run_at: ..t) }
  scope :active_scheduled, -> { where(status: :active) }
  # Inbox ordering: soonest upcoming first, undated/retired tasks last, newest
  # created break ties. Kept here so the controller never hand-writes SQL.
  scope :inbox, -> { includes(:agent, :scheduled_task_runs).order(Arel.sql("next_run_at ASC NULLS LAST, created_at DESC")) }

  # ── Scheduling math (the single source of truth) ─────────────────────────
  # Compute the next UTC fire instant for a recurring task, evaluating the cron
  # in the task's OWN timezone (so a 07:00 Asia/Colombo daily job stays at the
  # correct UTC instant across DST-relevant windows and midnight boundaries).
  # Assigns self.next_run_at (does NOT persist); returns the UTC Time or nil.
  def compute_next_run_at!(from: Time.current)
    self.next_run_at = if one_time?
      run_at&.utc
    else
      next_recurring_time(from)
    end
  end

  def due?(t = Time.current)
    active? && next_run_at.present? && next_run_at <= t
  end

  # Human-readable schedule for the /scheduled inbox, e.g.
  #   "Every day at 07:00 · Asia/Colombo", "One-time on Nov 1, 2026 07:00 · Asia/Colombo".
  def humanized_schedule
    base = one_time? ? humanized_one_time : humanized_cron
    "#{base} · #{timezone}"
  end

  # Flip to :failed once MAX_CONSECUTIVE_FAILURES is reached; returns whether it
  # tripped. Failure streak is tracked in metadata (no schema churn).
  def record_failure!
    meta = metadata.is_a?(Hash) ? metadata.dup : {}
    streak = meta.fetch("consecutive_failures", 0).to_i + 1
    meta["consecutive_failures"] = streak
    if recurring? && streak >= MAX_CONSECUTIVE_FAILURES
      update!(metadata: meta, status: :failed)
      true
    else
      update!(metadata: meta)
      false
    end
  end

  def record_success!
    return unless metadata.is_a?(Hash) && metadata.key?("consecutive_failures")

    meta = metadata.dup
    meta.delete("consecutive_failures")
    update!(metadata: meta)
  end

  private

  def next_recurring_time(from)
    return nil if cron.blank? || timezone.blank?

    # Fugit honours a trailing IANA zone in the expression and computes the next
    # occurrence in that zone, then yields the exact UTC instant.
    parsed = Fugit::Cron.parse("#{cron} #{timezone}")
    return nil unless parsed

    nt = parsed.next_time(from)
    nt&.to_t&.utc
  end

  def will_schedule_next_run?
    active? && (new_record? || schedule_changed? || cron_changed? || timezone_changed? ||
      run_at_changed? || will_save_change_to_run_at?)
  end

  def schedule_changed?
    changed.include?("schedule_type")
  end

  def materialize_next_run_at
    compute_next_run_at!(from: Time.current)
  end

  def apply_run_at_wall
    return unless @run_at_wall.present? && one_time?

    zone = ActiveSupport::TimeZone[timezone.presence || DEFAULT_TIMEZONE] || ActiveSupport::TimeZone[DEFAULT_TIMEZONE]
    self.run_at = zone.parse(@run_at_wall.to_s)&.utc
  end

  def timezone_is_valid
    return if timezone.blank?
    return if ActiveSupport::TimeZone[timezone].present?

    errors.add(:timezone, "is not a valid time zone")
  end

  def schedule_is_well_formed
    if recurring?
      errors.add(:cron, "is required for a recurring schedule") if cron.blank?
      errors.add(:run_at, "must be blank for a recurring schedule") if run_at.present?
      validate_cron_expression if cron.present?
    elsif one_time?
      errors.add(:run_at, "is required for a one-time schedule") if run_at.blank?
      errors.add(:cron, "must be blank for a one-time schedule") if cron.present?
    else
      errors.add(:schedule_type, "must be recurring or one_time")
    end
  end

  def validate_cron_expression
    # A bare cron must parse WITHOUT carrying its own zone (we append the task
    # timezone at compute time; a pre-zoned expression would double-append).
    bare = Fugit::Cron.parse(cron)
    if bare.nil?
      errors.add(:cron, "is not a valid cron expression")
    elsif !bare.timezone.nil?
      errors.add(:cron, "must not include a time zone (choose one in the Time zone field)")
    end
  end

  def humanized_cron
    parts = cron.to_s.split(" ")
    return cron.to_s unless parts.length >= 5

    minute, hour, dom, month, dow = parts[0, 5]
    day_desc, time_desc = nil, nil

    if minute =~ /\A\d+\z/ && hour =~ /\A\d+\z/
      time_desc = format("%02d:%02d", hour.to_i, minute.to_i)
    end

    day_desc =
      if dom == "*" && month == "*"
        case dow
        when "*" then "Every day"
        when "1-5", "1,2,3,4,5" then "Every weekday"
        when /\A\d\z/ then "Every #{weekday_name(dow.to_i)}"
        else "#{dow.inspect} days"
        end
      elsif dom =~ /\A\d+\z/ && month == "*" && dow == "*"
        "Every month on day #{dom}"
      else
        "Cron: #{cron}"
      end

    if time_desc && day_desc && !day_desc.start_with?("Cron:")
      "#{day_desc} at #{time_desc}"
    else
      day_desc
    end
  end

  def humanized_one_time
    return "One-time" if run_at.blank?

    "One-time on #{run_at.in_time_zone(timezone.presence || DEFAULT_TIMEZONE).strftime('%b %-d, %Y %H:%M')}"
  end

  def weekday_name(num)
    %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday][num] || "day"
  end
end
