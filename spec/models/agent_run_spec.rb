# spec/models/agent_run_spec.rb

# Narrative model specs: several assertions per example and allow/spy stubs
# are intentional, consistent with the integration specs in this repo.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/LetSetup, RSpec/StubbedMock, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe AgentRun, type: :model do
  subject(:agent_run) { build(:agent_run) }

  it "has a valid factory" do
    expect(build(:agent_run)).to be_valid
  end

  describe "associations" do
    it { is_expected.to belong_to(:conversation) }
    it { is_expected.to have_many(:todos).class_name("AgentTodo").dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:mode).in_array(AgentRun::MODES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(AgentRun::STATUSES) }
  end

  describe "scopes" do
    describe ".active" do
      let!(:planning_run) { create(:agent_run, status: "planning", conversation: create(:conversation)) }
      let!(:executing_run) { create(:agent_run, status: "executing", conversation: create(:conversation)) }
      let!(:completed_run) { create(:agent_run, status: "completed", conversation: create(:conversation)) }
      let!(:interrupted_run) { create(:agent_run, status: "interrupted", conversation: create(:conversation)) }

      it "returns runs with planning or executing status" do
        expect(described_class.active).to contain_exactly(planning_run, executing_run)
      end
    end
  end

  describe "#auto?" do
    it { expect(build(:agent_run, mode: "auto_build")).to be_auto }
    it { expect(build(:agent_run, mode: "auto_plan")).to be_auto }
    it { expect(build(:agent_run, mode: "manual_build")).not_to be_auto }
    it { expect(build(:agent_run, mode: "manual_plan")).not_to be_auto }
  end

  describe "#plan_first?" do
    it { expect(build(:agent_run, mode: "manual_plan")).to be_plan_first }
    it { expect(build(:agent_run, mode: "auto_plan")).to be_plan_first }
    it { expect(build(:agent_run, mode: "manual_build")).not_to be_plan_first }
    it { expect(build(:agent_run, mode: "auto_build")).not_to be_plan_first }
  end

  describe "#build?" do
    it { expect(build(:agent_run, mode: "manual_build")).to be_build }
    it { expect(build(:agent_run, mode: "auto_build")).to be_build }
    it { expect(build(:agent_run, mode: "manual_plan")).not_to be_build }
    it { expect(build(:agent_run, mode: "auto_plan")).not_to be_build }
  end

  describe "#append_reasoning" do
    let(:agent_run) { create(:agent_run) }
    let(:frozen_time) { Time.zone.local(2026, 6, 8, 12, 0, 0) }

    around { |ex| travel_to(frozen_time, &ex) }

    before do
      allow(agent_run).to receive(:broadcast_reasoning)
    end

    it "appends a reasoning step with timestamp" do
      agent_run.append_reasoning("Parse user intent", "User wants to check weather")
      steps = agent_run.reload.reasoning_steps

      expect(steps.size).to eq(1)
      expect(steps[0]["step"]).to eq("Parse user intent")
      expect(steps[0]["detail"]).to eq("User wants to check weather")
      expect(steps[0]["t"]).to eq("2026-06-08T12:00:00Z")
    end

    it "appends multiple steps in order" do
      agent_run.append_reasoning("Step one")
      agent_run.append_reasoning("Step two", "Details for step two")

      steps = agent_run.reload.reasoning_steps
      expect(steps.size).to eq(2)
      expect(steps[0]["step"]).to eq("Step one")
      expect(steps[1]["detail"]).to eq("Details for step two")
    end

    it "handles nil detail" do
      agent_run.append_reasoning("No detail step")
      steps = agent_run.reload.reasoning_steps

      expect(steps.size).to eq(1)
      expect(steps[0]["step"]).to eq("No detail step")
      expect(steps[0]).to have_key("detail")
      expect(steps[0]["detail"]).to be_nil
    end

    it "calls broadcast_reasoning after appending" do
      expect(agent_run).to receive(:broadcast_reasoning).once
      agent_run.append_reasoning("Broadcast test")
    end

    it "preserves existing steps when appending" do
      agent_run.update!(reasoning_steps: [ { "step" => "pre-existing", "t" => "2026-01-01T00:00:00Z" } ])
      agent_run.append_reasoning("New step")

      steps = agent_run.reload.reasoning_steps
      expect(steps.size).to eq(2)
      expect(steps[0]["step"]).to eq("pre-existing")
      expect(steps[1]["step"]).to eq("New step")
    end

    it "works when reasoning_steps is nil" do
      agent_run.update_column(:reasoning_steps, nil)
      agent_run.append_reasoning("First step after nil")

      steps = agent_run.reload.reasoning_steps
      expect(steps.size).to eq(1)
      expect(steps[0]["step"]).to eq("First step after nil")
    end
  end

  describe "#broadcast_reasoning" do
    let(:agent_run) { create(:agent_run) }

    it "broadcasts a Turbo Stream replace to reasoning-#{id}" do
      expected_target = "reasoning-#{agent_run.id}"

      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        agent_run.conversation,
        hash_including(target: expected_target)
      )

      agent_run.broadcast_reasoning
    end
  end

  describe "after_update_commit :broadcast_status" do
    let(:agent_run) { create(:agent_run, status: "planning") }

    before do
      allow(agent_run).to receive(:broadcast_status).and_call_original
    end

    it "triggers broadcast_status when status changes" do
      expect(agent_run).to receive(:broadcast_status)
      agent_run.update!(status: "executing")
    end

    it "does not trigger broadcast_status when status is unchanged" do
      expect(agent_run).not_to receive(:broadcast_status)
      agent_run.update!(current_step: 1)
    end

    it "broadcasts a Turbo Stream replace to run-status-#{id}" do
      expected_target = "run-status-#{agent_run.id}"

      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_to).with(
        agent_run.conversation,
        hash_including(target: expected_target)
      )

      agent_run.update!(status: "executing")
    end
  end

  describe "invalid states" do
    it "rejects unknown mode" do
      run = build(:agent_run, mode: "unknown_mode")
      expect(run).not_to be_valid
      expect(run.errors[:mode]).to include("is not included in the list")
    end

    it "rejects unknown status" do
      run = build(:agent_run, status: "unknown_status")
      expect(run).not_to be_valid
      expect(run.errors[:status]).to include("is not included in the list")
    end

    it "rejects nil conversation" do
      run = build(:agent_run, conversation: nil)
      expect(run).not_to be_valid
      expect(run.errors[:conversation]).to include("must exist")
    end
  end

  describe "defaults" do
    it "defaults mode to auto_plan" do
      expect(described_class.column_defaults["mode"]).to eq("auto_plan")
    end

    it "defaults status to planning" do
      expect(described_class.column_defaults["status"]).to eq("planning")
    end

    it "defaults reasoning_steps to empty array" do
      expect(described_class.column_defaults["reasoning_steps"]).to eq([])
    end
  end

  describe "todos lifecycle" do
    let(:agent_run) { create(:agent_run) }

    it "destroys associated todos when run is destroyed" do
      create(:agent_todo, agent_run: agent_run)
      create(:agent_todo, agent_run: agent_run)

      expect { agent_run.destroy! }.to change(AgentTodo, :count).by(-2)
    end
  end

  # ── #verify_outputs! — no false build success ────────────────────────

  # Narrative verification suite: several assertions per example by design.
  # rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/LetSetup
  describe "#verify_outputs!" do
    let(:run) { create(:agent_run, mode: "auto_build", status: "executing") }

    def done_todo(title, result: "wrote it")
      create(:agent_todo, agent_run: run, title: title, status: "done", result: result, position: run.todos.size)
    end

    before do
      allow(run).to receive(:broadcast_reasoning)
      allow(run).to receive(:broadcast_status)
    end

    it "completes when every promised file exists" do
      path = "/tmp/shams-verify-spec-#{SecureRandom.hex(4)}/generated.py"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x")
      done_todo("Write '#{path}'")
      done_todo("Create the project directory at '#{File.dirname(path)}'")

      expect(run.verify_outputs!).to eq("completed")
      expect(run.reload.status).to eq("completed")
      expect(run.todos.where(status: "done").count).to eq(2)
    ensure
      FileUtils.rm_rf(File.dirname(path))
    end

    it "downgrades done steps whose promised file is missing and fails the run" do
      missing = "/tmp/shams-verify-spec-#{SecureRandom.hex(4)}-absent/src/model.py"
      done_todo("Write '#{missing}'", result: "I'm sorry, I couldn't generate a response.")

      expect(run.verify_outputs!).to eq("failed")
      expect(run.reload.status).to eq("failed")

      todo = run.todos.reload.first
      expect(todo.status).to eq("failed")
      expect(todo.result).to include("Output verification:")
      expect(todo.result).to include(missing)
      expect(run.reasoning_steps.last["step"]).to eq("Output verification")
      expect(run.reasoning_steps.last["detail"]).to include("run marked failed")
    end

    it "keeps truly-present targets done while failing only missing ones" do
      path = "/tmp/shams-verify-spec-#{SecureRandom.hex(4)}/README.md"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "readme")
      missing = "/tmp/shams-verify-spec-#{SecureRandom.hex(4)}-missing/src/module.rb"
      done_todo("Write '#{path}'")
      done_todo("Write '#{missing}'")

      expect(run.verify_outputs!).to eq("failed")
      statuses = run.todos.reload.pluck(:status)
      expect(statuses).to include("done")
      expect(statuses).to include("failed")
    ensure
      FileUtils.rm_rf(File.dirname(path))
    end

    it "ignores done steps without quoted path targets" do
      done_todo("Install dependencies")

      expect(run.verify_outputs!).to eq("completed")
      expect(run.todos.reload.first.status).to eq("done")
    end

    it "verifies only done steps — failed and pending steps are not checked" do
      create(:agent_todo, agent_run: run, title: "Write '/tmp/absent-from-failed-step/x.py'", status: "failed", result: "step failed")
      create(:agent_todo, agent_run: run, title: "Write '/tmp/absent-from-pending-step/x.py'", status: "pending", position: 1)

      expect(run.verify_outputs!).to eq("completed")
    end

    it "does not verify non-build runs" do
      plan_run = create(:agent_run, mode: "auto_plan", status: "executing")
      create(:agent_todo, agent_run: plan_run, title: "Write '/tmp/non-build-missing/x.py'", status: "done", result: "done")

      expect(plan_run.verify_outputs!).to eq("completed")
      expect(plan_run.todos.reload.first.status).to eq("done")
    end

    it "leaves interrupted runs untouched" do
      interrupted = create(:agent_run, mode: "auto_build", status: "interrupted")
      create(:agent_todo, agent_run: interrupted, title: "Write '/tmp/interrupted-missing/x.py'", status: "done", result: "done")

      expect(interrupted.verify_outputs!).to eq("interrupted")
      expect(interrupted.reload.status).to eq("interrupted")
      expect(interrupted.todos.reload.first.status).to eq("done")
    end
  end
  # rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/LetSetup
end
