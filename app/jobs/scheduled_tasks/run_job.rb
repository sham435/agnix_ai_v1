# frozen_string_literal: true

module ScheduledTasks
  # Executes one due ScheduledTask occurrence. It reuses the EXACT streaming code
  # path a normal chat send uses — AgentStreamJob — rather than duplicating the
  # runner/tool-loop/streaming logic. AgentStreamJob finalizes the assistant
  # placeholder it creates for the given request_id, so after it returns we
  # inspect that row to decide success vs. failure.
  #
  # Outcome wiring (all state transitions are model methods, not raw SQL here):
  #   * success   -> run.succeeded + assistant_message + tokens; one-time task
  #                  completes; a recurring task completes once it hits max_runs
  #                  or expires_at, otherwise stays active.
  #   * failure   -> run.failed + error text; recurring tasks record a failure
  #                  streak and flip to :failed after MAX_CONSECUTIVE_FAILURES.
  #
  # Best-effort Turbo broadcasts refresh the /scheduled inbox + sidebar badge;
  # with no live subscriber they are harmless no-ops.
  class RunJob < ApplicationJob
    queue_as :agents

    def perform(scheduled_task_id)
      task = ScheduledTask.find_by(id: scheduled_task_id)
      return if task.nil?

      run = task.scheduled_task_runs.create!(status: :queued, conversation_id: task.conversation_id)
      run.mark_running!

      conversation = ensure_conversation(task)
      run.update!(conversation: conversation)

      request_id = SecureRandom.uuid
      user_message = conversation.messages.create!(role: :user, content: task.prompt)

      # Reuse the canonical streaming path (creates + finalizes the assistant
      # placeholder tagged with this request_id).
      AgentStreamJob.perform_now(
        conversation_id: conversation.id,
        user_id: task.user_id,
        message_content: user_message.content,
        message_id: user_message.id,
        request_id: request_id
      )

      assistant = locate_assistant(conversation, request_id)
      if successful_reply?(assistant)
        handle_success(task, run, assistant)
      else
        raise NoResponseError, "The agent produced no response for this scheduled run."
      end
    rescue StandardError => e
      handle_failure(task, run, e) if task && run
      raise if task.nil? || run.nil? # let genuine setup errors surface to the queue
    ensure
      broadcast_refresh(task)
    end

    # Raised when the reused streaming path leaves us with nothing renderable.
    class NoResponseError < StandardError; end

    private

    def ensure_conversation(task)
      return task.conversation if task.conversation.present?

      conversation = Conversation.create!(
        user: task.user,
        agent: task.agent,
        title: task.name.to_s.truncate(50, omission: "..."),
        metadata: { "scheduled_task_id" => task.id }
      )
      task.update!(conversation: conversation)
      conversation
    end

    def locate_assistant(conversation, request_id)
      conversation.messages.where(role: :assistant)
        .where("metadata->>'request_id' = ?", request_id)
        .order(:created_at).last
    end

    def successful_reply?(message)
      message.present? && message.content.to_s.strip.present? && !message.empty_response?
    end

    def handle_success(task, run, assistant)
      run.mark_succeeded!(assistant_message: assistant, tokens: assistant.tokens.to_i)
      task.record_success!

      if task.one_time?
        task.update!(status: :completed, next_run_at: nil)
      elsif recurring_exhausted?(task)
        task.update!(status: :completed, next_run_at: nil)
      end
    end

    def recurring_exhausted?(task)
      return false unless task.recurring?

      max_runs_hit?(task) || expires_hit?(task)
    end

    def max_runs_hit?(task)
      task.max_runs.present? && task.run_count >= task.max_runs
    end

    def expires_hit?(task)
      task.expires_at.present? && task.expires_at <= Time.current
    end

    def handle_failure(task, run, error)
      run.mark_failed!(error.message) if run.persisted? && !run.succeeded?
      task.record_failure! if task.persisted?
      Rails.logger.error "[ScheduledTasks::RunJob] FAILED task=#{task&.id} run=#{run&.id} #{error.class}: #{error.message}"
    rescue StandardError => e
      Rails.logger.error "[ScheduledTasks::RunJob] FAILURE-RECORD-ERROR #{e.class}: #{e.message}"
    end

    def broadcast_refresh(task)
      return if task.nil?

      payload = { scheduled_task_id: task.id, status: task.status, next_run_at: task.next_run_at&.iso8601 }
      Turbo::StreamsChannel.broadcast_update_to(
        "scheduled_tasks", target: "scheduled-task-#{task.id}",
        html: ApplicationController.render(
          partial: "scheduled_tasks/task", locals: { task: task.reload }, layout: false
        )
      )
      Rails.logger.info "[ScheduledTasks::RunJob] broadcast #{payload.inspect}"
    rescue StandardError => e
      # Inbox refresh is best-effort only — never fail the run over a broadcast.
      Rails.logger.error "[ScheduledTasks::RunJob] BROADCAST-ERROR #{e.class}: #{e.message}"
    end
  end
end
