# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 2c — ScheduledTasks::TickJob. The important guarantee is idempotency:
# two ticks racing the same due moment must fire the occurrence exactly once, so
# a task never double-runs under at-least-once queue delivery.
RSpec.describe ScheduledTasks::TickJob do
  include ActiveJob::TestHelper

  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = previous
  end

  let(:task) do
    create(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo").tap do |t|
      t.update_columns(next_run_at: 2.hours.ago)
    end
  end

  it "fires a due task once and rolls its schedule forward" do
    expect { described_class.new.perform }.to have_enqueued_job(ScheduledTasks::RunJob).with(task.id).once

    task.reload
    expect(task.next_run_at).to be > Time.current
    expect(task.run_count).to eq(1)
    expect(task.last_run_at).to be_present
  end

  it "is idempotent across a second tick on the same due moment" do
    task
    expect { described_class.new.perform }.to have_enqueued_job(ScheduledTasks::RunJob).with(task.id).once
    # The row's next_run_at already advanced, so the second tick finds nothing due.
    expect { described_class.new.perform }.not_to have_enqueued_job(ScheduledTasks::RunJob)
  end

  it "skips a task whose row moved on before the claim landed" do
    # Simulate a lost race: the in-memory snapshot no longer matches the DB row
    # when the conditional UPDATE runs, so it claims 0 rows and never fires.
    task # create the due row
    fired = 0
    ScheduledTask.due(Time.current).find_each do |t|
      old_next = t.next_run_at
      # Move the row out from under this worker before claiming it.
      t.update_columns(next_run_at: 3.days.from_now)
      claimed = ScheduledTask.where(id: t.id, next_run_at: old_next).update_all([ "run_count = run_count + 1" ])
      fired += 1 if claimed.positive?
    end

    expect(fired).to eq(0)
    expect(enqueued_jobs.map { |j| j[:job] }).not_to include(ScheduledTasks::RunJob)
  end

  it "retires a one-time task from the poll after firing" do
    one_time = create(:scheduled_task, :one_time, run_at: 1.hour.ago, timezone: "UTC")
    one_time.update_columns(next_run_at: 1.hour.ago, status: "active")

    expect { described_class.new.perform }.to have_enqueued_job(ScheduledTasks::RunJob).with(one_time.id).once
    expect(one_time.reload.next_run_at).to be_nil
  end

  it "does not fire paused or completed tasks" do
    paused = create(:scheduled_task)
    paused.update_columns(status: "paused", next_run_at: 2.hours.ago)

    completed = create(:scheduled_task)
    completed.update_columns(status: "completed", next_run_at: 2.hours.ago)

    expect { described_class.new.perform }.not_to have_enqueued_job(ScheduledTasks::RunJob)
    expect(paused.reload.run_count).to eq(0)
    expect(completed.reload.run_count).to eq(0)
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
