# frozen_string_literal: true

module ScheduledTasks
  # Polls due recurring/one-time tasks and fires each exactly once. Driven by
  # config/recurring.yml (every 1 minute in production) and directly from specs.
  #
  # Idempotency: before enqueuing RunJob we *claim* the occurrence with a
  # conditional UPDATE guarded on the task's previous next_run_at. Two ticks
  # racing the same due moment collapse to a single winner (0 rows updated for
  # the loser), so an occurrence never double-fires even under Solid Queue's
  # at-least-once delivery.
  class TickJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100

    def perform(now = nil)
      now = now.present? ? Time.zone.parse(now.to_s) : Time.current
      fired = 0

      ScheduledTask.due(now).order(:next_run_at).limit(BATCH_SIZE).find_each do |task|
        fired += 1 if claim_and_enqueue(task, now)
      end

      Rails.logger.info "[ScheduledTasks::TickJob] tick at=#{now.iso8601} fired=#{fired}"
      fired
    end

    private

    def claim_and_enqueue(task, now)
      old_next = task.next_run_at
      # A recurring task rolls forward to its next slot; a one-time task is
      # retired from the poll (RunJob finalises its :completed status).
      new_next = task.recurring? ? task.compute_next_run_at!(from: now) : nil

      claimed = ScheduledTask
        .where(id: task.id, next_run_at: old_next)
        .update_all([ "last_run_at = ?, run_count = run_count + 1, next_run_at = ?, updated_at = ?",
                     now, new_next, now ])
      return false if claimed.zero?

      RunJob.perform_later(task.id)
      true
    rescue StandardError => e
      Rails.logger.error "[ScheduledTasks::TickJob] ERROR task=#{task.id} #{e.class}: #{e.message}"
      false
    end
  end
end
