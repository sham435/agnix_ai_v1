# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

# ensure_for and workspace_status are the two places where a workspace's state
# is decided, and both had to answer the same question honestly: a sandbox that
# was stopped on purpose is not a broken one, and asking for it again restarts
# it under the id the manager already knows.
RSpec.describe Workspaces::Provider do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  def stub_running
    allow(Workspaces::ManagerClient).to receive(:post)
      .with("/workspaces", hash_including(:id, runtime: "python3"))
      .and_return({ "ok" => true, "status" => { "state" => "running" } })
    allow(Workspaces::ManagerClient).to receive(:get)
      .and_return({ "state" => "running", "preview" => { "state" => "absent" } })
  end

  describe "ensure_for" do
    it "creates one sandbox for the conversation" do
      stub_running

      workspace = described_class.ensure_for(conversation: conversation, user: user, name: "Flask app")

      expect(workspace).to be_persisted
      expect(workspace.state).to eq("ready")
      expect(Workspace.where(conversation: conversation).count).to eq(1)
    end

    it "reuses the live sandbox instead of starting a second container" do
      existing = create(:workspace, user: user, conversation: conversation, state: "ready")
      allow(Workspaces::ManagerClient).to receive(:post)
      allow(Workspaces::ManagerClient).to receive(:get)
        .and_return({ "state" => "running", "preview" => { "state" => "absent" } })

      expect(described_class.ensure_for(conversation: conversation, user: user)).to eq(existing)
      expect(Workspaces::ManagerClient).not_to have_received(:post)
    end

    it "restarts a stopped sandbox under the same id rather than inserting a second row" do
      stopped = create(:workspace, user: user, conversation: conversation, state: "destroyed",
                                    destroyed_at: 2.hours.ago)
      stub_running

      restarted = described_class.ensure_for(conversation: conversation, user: user)

      expect(restarted.id).to eq(stopped.id)
      expect(restarted.state).to eq("ready")
      expect(restarted.reload.destroyed_at).to be_nil
      expect(Workspace.where(conversation: conversation).count).to eq(1)
    end
  end

  describe "workspace_status" do
    it "keeps a deliberately stopped workspace stopped when its container is gone" do
      stopped = create(:workspace, user: user, state: "destroyed", destroyed_at: 2.hours.ago)
      allow(Workspaces::ManagerClient).to receive(:get).and_return({ "state" => "absent" })

      described_class.workspace_status(stopped)

      expect(stopped.reload.state).to eq("destroyed")
    end

    it "reports a workspace that vanished without being stopped as failed" do
      running = create(:workspace, user: user, state: "ready")
      allow(Workspaces::ManagerClient).to receive(:get).and_return({ "state" => "absent" })

      described_class.workspace_status(running)

      expect(running.reload.state).to eq("failed")
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
