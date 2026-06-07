# spec/models/agent_run_spec.rb

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
      agent_run.update!(reasoning_steps: [{ "step" => "pre-existing", "t" => "2026-01-01T00:00:00Z" }])
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
end
