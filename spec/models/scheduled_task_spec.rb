# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 2b — ScheduledTask. Validations, the timezone-aware next-run math, and
# the failure-streak bookkeeping that flips a task to :failed. All scheduling
# math lives here (never in jobs/controllers/views).
RSpec.describe ScheduledTask do
  subject(:task) do
    build(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo", schedule_type: "recurring")
  end

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:organization) }
    it { is_expected.to belong_to(:agent) }
    it { is_expected.to belong_to(:conversation).optional }
    it { is_expected.to have_many(:scheduled_task_runs).dependent(:destroy) }
  end

  describe "enums" do
    it { is_expected.to define_enum_for(:schedule_type).with_values(recurring: "recurring", one_time: "one_time").backed_by_column_of_type(:string) }
    it { is_expected.to define_enum_for(:status).with_values(active: "active", paused: "paused", completed: "completed", failed: "failed", cancelled: "cancelled").backed_by_column_of_type(:string) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:prompt) }
    it { is_expected.to validate_presence_of(:timezone) }
    it { is_expected.to validate_numericality_of(:max_runs).is_greater_than_or_equal_to(1).only_integer }

    it "is valid for a well-formed recurring schedule" do
      expect(build(:scheduled_task)).to be_valid
    end

    it "rejects a recurring task without a cron" do
      t = build(:scheduled_task, cron: nil)
      expect(t).not_to be_valid
      expect(t.errors[:cron]).to include(/required/)
    end

    it "rejects a one-time task without run_at" do
      t = build(:scheduled_task, :one_time, run_at: nil)
      expect(t).not_to be_valid
      expect(t.errors[:run_at]).to include(/required/)
    end

    it "rejects a recurring task that also carries run_at (exactly one rule)" do
      t = build(:scheduled_task, run_at: 1.day.from_now)
      expect(t).not_to be_valid
      expect(t.errors[:run_at]).to include(/must be blank/)
    end

    it "rejects an unknown timezone" do
      t = build(:scheduled_task, timezone: "Mars/Olympus")
      expect(t).not_to be_valid
      expect(t.errors[:timezone]).to include(/valid time zone/)
    end

    it "rejects an invalid cron expression" do
      expect(build(:scheduled_task, cron: "99 99 99 99 99")).not_to be_valid
    end

    it "rejects a cron that already carries a timezone (would double-append)" do
      t = build(:scheduled_task, cron: "0 7 * * * Europe/Paris")
      expect(t).not_to be_valid
      expect(t.errors[:cron]).to include(/must not include a time zone/)
    end

    it "rejects max_runs below 1" do
      expect(build(:scheduled_task, max_runs: 0)).not_to be_valid
    end
  end

  describe "#compute_next_run_at!" do
    it "evaluates a daily Asia/Colombo cron at the correct UTC instant" do
      t = create(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo", status: :paused)
      result = t.compute_next_run_at!(from: Time.utc(2026, 10, 24, 20, 0, 0))
      # 07:00 +0530 == 01:30 UTC the next local day.
      expect(result).to eq(Time.utc(2026, 10, 25, 1, 30, 0))
    end

    it "crosses a UTC midnight boundary correctly" do
      t = create(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo", status: :paused)
      # 08:00 local is already past 07:00 -> next is tomorrow's 01:30 UTC.
      result = t.compute_next_run_at!(from: Time.utc(2026, 10, 25, 2, 30, 0))
      expect(result).to eq(Time.utc(2026, 10, 26, 1, 30, 0))
    end

    it "tracks a DST shift: New York 07:00 moves from 12:00 UTC to 11:00 UTC" do
      t = create(:scheduled_task, cron: "0 7 * * *", timezone: "America/New_York", status: :paused)
      before_dst = t.compute_next_run_at!(from: Time.utc(2026, 3, 6, 0, 0, 0))
      expect(before_dst).to eq(Time.utc(2026, 3, 6, 12, 0, 0)) # EST = UTC-5

      after_dst = t.compute_next_run_at!(from: Time.utc(2026, 3, 9, 0, 0, 0))
      expect(after_dst).to eq(Time.utc(2026, 3, 9, 11, 0, 0)) # EDT = UTC-4
    end

    it "assigns next_run_at in-memory without persisting" do
      t = build(:scheduled_task, cron: "*/15 * * * *", timezone: "UTC", status: :paused)
      t.compute_next_run_at!(from: Time.utc(2026, 1, 1, 0, 1, 0))
      expect(t.next_run_at).to eq(Time.utc(2026, 1, 1, 0, 15, 0))
    end

    it "sets next_run_at to run_at for a one-time task" do
      when_time = Time.utc(2026, 12, 1, 9, 0, 0)
      t = create(:scheduled_task, :one_time, run_at: when_time, timezone: "UTC", status: :paused)
      expect(t.compute_next_run_at!(from: Time.utc(2026, 11, 1))).to eq(when_time)
    end

    it "materialises next_run_at automatically on create for an active task" do
      freeze_time do
        t = create(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo")
        expect(t.next_run_at).to be_present
        expect(t.next_run_at).to be > Time.current
      end
    end
  end

  describe "failure streak bookkeeping" do
    it "flips a recurring task to failed after the consecutive-failure threshold" do
      t = create(:scheduled_task)
      (ScheduledTask::MAX_CONSECUTIVE_FAILURES - 1).times { t.record_failure! }
      expect(t.reload).to be_active

      expect(t.record_failure!).to be(true)
      expect(t.reload).to be_failed
    end

    it "keeps a one-time task failing on the first failure (no retry)" do
      t = create(:scheduled_task, :one_time)
      expect(t.record_failure!).to be(false)
    end

    it "clears the streak on success" do
      t = create(:scheduled_task)
      t.record_failure!
      expect(t.reload.metadata["consecutive_failures"]).to eq(1)
      t.record_success!
      expect(t.reload.metadata).not_to have_key("consecutive_failures")
    end
  end

  describe "#humanized_schedule" do
    it "describes a daily cron with the timezone" do
      expect(build(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo").humanized_schedule)
        .to eq("Every day at 07:00 · Asia/Colombo")
    end

    it "describes a weekday cron" do
      expect(build(:scheduled_task, cron: "0 9 * * 1-5", timezone: "UTC").humanized_schedule)
        .to eq("Every weekday at 09:00 · UTC")
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
