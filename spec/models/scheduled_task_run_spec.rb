# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

# Phase 2b — ScheduledTaskRun: the per-execution log for a ScheduledTask.
RSpec.describe ScheduledTaskRun do
  subject(:run) { build(:scheduled_task_run) }

  describe "associations" do
    it { is_expected.to belong_to(:scheduled_task) }
    it { is_expected.to belong_to(:conversation).optional }
    it { is_expected.to belong_to(:assistant_message).optional }
  end

  describe "status enum" do
    it { is_expected.to define_enum_for(:status).with_values(queued: "queued", running: "running", succeeded: "succeeded", failed: "failed").backed_by_column_of_type(:string) }
  end

  describe "state transitions" do
    it "marks running and stamps started_at once" do
      run.save!
      run.mark_running!
      expect(run).to be_running
      expect(run.started_at).to be_present
    end

    it "marks succeeded with the assistant message and tokens" do
      task = create(:scheduled_task)
      message = create(:message, conversation: create(:conversation, user: task.user, agent: task.agent), role: :assistant, content: "done", tokens: 12)
      run = create(:scheduled_task_run, scheduled_task: task)
      run.mark_succeeded!(assistant_message: message, tokens: message.tokens)
      expect(run).to be_succeeded
      expect(run.assistant_message).to eq(message)
      expect(run.conversation).to eq(message.conversation)
      expect(run.tokens).to eq(12)
      expect(run.finished_at).to be_present
    end

    it "marks failed with a truncated error" do
      run = create(:scheduled_task_run)
      run.mark_failed!("x" * 5000)
      expect(run).to be_failed
      expect(run.error.length).to be <= 1000
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
