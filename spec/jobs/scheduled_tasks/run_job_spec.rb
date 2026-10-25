# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 2c — ScheduledTasks::RunJob wiring. RunJob reuses AgentStreamJob (the
# exact streaming/tool-loop path a normal chat send uses); we stub that single
# boundary to simulate a successful generation or an empty/failed one, so these
# specs never touch a real LLM (CI-safe) yet still exercise RunJob's own outcome
# logic: conversation creation, run-row transitions, and task completion rules.
RSpec.describe ScheduledTasks::RunJob do
  let(:task) { create(:scheduled_task, cron: "0 7 * * *", timezone: "Asia/Colombo") }

  # Stub the reused streaming path to write the assistant row AgentStreamJob
  # would have finalized for this request_id.
  def stub_streaming_reply(content: "Automated answer", tokens: 128)
    allow(AgentStreamJob).to receive(:perform_now) do |conversation_id:, request_id:, **|
      conv = Conversation.find(conversation_id)
      conv.messages.create!(role: :assistant, content: content, tokens: tokens,
                                   metadata: { "request_id" => request_id })
    end
  end

  def stub_no_reply
    allow(AgentStreamJob).to receive(:perform_now)
  end

  describe "success" do
    before { stub_streaming_reply }

    it "creates a titled conversation, records a succeeded run and links the assistant message" do
      expect { described_class.perform_now(task.id) }
        .to change(ScheduledTaskRun, :count).by(1)

      run = task.scheduled_task_runs.reload.first
      expect(run).to be_succeeded
      expect(run.tokens).to eq(128)
      expect(run.assistant_message).to be_present
      expect(run.conversation).to eq(task.reload.conversation)
      expect(task.conversation.title).to eq(task.name)
      expect(task.conversation.metadata["scheduled_task_id"]).to eq(task.id)
      expect(task.conversation.messages.where(role: :user).last.content).to eq(task.prompt)
    end

    it "keeps a recurring task active (schedule already advanced by the tick)" do
      described_class.perform_now(task.id)
      expect(task.reload).to be_active
    end

    it "completes a one-time task after success" do
      one_time = create(:scheduled_task, :one_time, run_at: 1.hour.ago, timezone: "UTC")
      one_time.update_columns(status: "active", next_run_at: 1.hour.ago)

      described_class.perform_now(one_time.id)
      expect(one_time.reload).to be_completed
      expect(one_time.next_run_at).to be_nil
    end

    it "completes a recurring task that has hit max_runs" do
      task.update_columns(max_runs: 1, run_count: 1)
      described_class.perform_now(task.id)
      expect(task.reload).to be_completed
    end

    it "completes a recurring task that is past expires_at" do
      task.update_columns(expires_at: 1.minute.ago)
      described_class.perform_now(task.id)
      expect(task.reload).to be_completed
    end

    it "clears any prior failure streak on success" do
      task.record_failure!
      described_class.perform_now(task.id)
      expect(task.reload.metadata).not_to have_key("consecutive_failures")
    end
  end

  describe "failure" do
    before { stub_no_reply }

    it "records a failed run and leaves a recurring task active on the first miss" do
      described_class.perform_now(task.id)
      run = task.scheduled_task_runs.reload.first
      expect(run).to be_failed
      expect(run.error).to be_present
      expect(task.reload).to be_active
      expect(task.metadata["consecutive_failures"]).to eq(1)
    end

    it "flips a recurring task to failed once the streak threshold is reached" do
      ScheduledTask::MAX_CONSECUTIVE_FAILURES.times do
        described_class.perform_now(task.id)
        task.reload.update_columns(next_run_at: task.next_run_at) # no-op keep
      end
      expect(task.reload).to be_failed
    end

    it "is a no-op for a missing task" do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
      expect(ScheduledTaskRun.count).to eq(0)
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
