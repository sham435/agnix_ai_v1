# frozen_string_literal: true

# Narrative runner regressions keep the action, persisted evidence, and verdict together.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/AnyInstance, RSpec/MessageSpies, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# Regression specs for the school-build-run false-success bug (task
# shams-agentic-os): plan steps were marked "done" on responses that executed
# NO tool action at all — a text-only apology, or the max-iterations fallback.
# Evidence gating: a step completes only with executed actions and no error /
# iteration exhaustion. Workspace write results retain the provider's verification evidence.
RSpec.describe AgentRunner, type: :service do
  let(:organization) { create(:organization) }
  let(:agent) { create(:agent) }
  let(:user) { create(:user) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:client) { instance_double(Llm::Client) }

  before do
    allow(agent).to receive(:llm_client).and_return(client)
    allow(Workspaces::Provider).to receive(:available?).and_return({ manager: false, docker: false })
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow_any_instance_of(AgentRun).to receive(:broadcast_reasoning)
    # :inline queue adapter would hit the real embeddings endpoint.
    allow(EmbeddingJob).to receive(:perform_later).and_return(true)
  end

  describe "evidence gating (school-run regression)" do
    it "marks a step FAILED when the model replies text-only without any tool action" do
      agent_run = create(:agent_run, conversation: conversation, mode: "auto_build", status: "executing")
      create(:agent_todo, agent_run: agent_run, position: 0, title: "Write models.py", status: "pending")
      allow(client).to receive(:chat).and_return(
        { content: "I can't run or verify those steps myself — I have no shell access.", tool_calls: [], tokens: 8 }
      )

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      runner.resume_plan(agent_run, stream: false)

      todo = agent_run.reload.todos.first
      expect(todo.status).to eq("failed")
      expect(todo.result.to_s).to include("No tool action was executed")
      # The assistant apology is preserved in the conversation, not lost.
      expect(conversation.messages.assistant.map(&:content).join).to include("no shell access")
    end

    it "fails a step when a crafted host call is refused despite a model success claim" do
      conversation.update!(mode: "auto_build")
      allow(agent).to receive(:enabled_tools).and_return([ "write_file" ])
      allow(client).to receive(:chat).and_return(
        { content: nil, tool_calls: [ { id: "host", function: { name: "write_file", arguments: "{}" } } ], tokens: 1 },
        { content: "Wrote it (allegedly).", tool_calls: [], tokens: 1 }
      )
      expect(Agents::ToolRegistry).not_to receive(:execute)
      runner = described_class.new(agent: agent, conversation: conversation, user: user)

      result = runner.send(:execute_step, "Write models.py", false)

      expect(result[:ok]).to be(false)
      expect(result[:actions]).to eq(0)
      expect(Run.last.tool_checkpoint.first["ok"]).to be(false)
    end

    it "marks a step FAILED when the loop hit the iteration limit (incomplete marker)" do
      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      allow(runner).to receive(:execute_tool_loop).and_return(
        {
          content: "I was unable to complete your request within the allowed iterations.",
          tool_calls: [], tokens: 0, actions: 4, incomplete: true
        }
      )

      result = runner.send(:execute_step, "Run the test suite and report the results", false)

      expect(result[:ok]).to be(false)
      expect(result[:output]).to include("did not finish within the iteration limit")
      expect(result[:actions]).to eq(4)
    end

    it "completes a step when actions executed and no error is present" do
      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      allow(runner).to receive(:execute_tool_loop).and_return(
        { content: "wrote 3 files and ran tests", tool_calls: [], tokens: 0, actions: 5 }
      )

      result = runner.send(:execute_step, "Write the source files", false)

      expect(result[:ok]).to be(true)
      expect(result[:output]).to eq("wrote 3 files and ran tests")
    end

    it "fails a step whose loop raised an error even when actions executed" do
      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      allow(runner).to receive(:execute_tool_loop).and_return(
        { content: "boom", error: "total loss", tool_calls: [], tokens: 0, actions: 2 }
      )

      result = runner.send(:execute_step, "Install dependencies", false)

      expect(result[:ok]).to be(false)
      expect(result[:output]).to include("total loss")
    end
  end

  describe "workspace write evidence" do
    let(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }
    let(:workspace) { build_stubbed(:workspace, user: user, conversation: conversation) }
    let(:args) { { "path" => "models.py", "content" => "class Student:\n    pass\n" } }

    before do
      allow(agent).to receive(:enabled_tools).and_return([ "workspace_write_file" ])
      allow(Workspaces::ToolSupport).to receive(:with_workspace).and_yield(workspace)
    end

    it "preserves a workspace write verification failure instead of recording success" do
      allow(Workspaces::Provider).to receive(:write_file)
        .with(workspace, args["path"], args["content"])
        .and_return({ ok: false, error: "write verification failed: file missing or empty after write" })

      result = runner.send(:dispatch_tool_call, "workspace_write_file", args)

      expect(result[:error]).to include("write verification failed")
      expect(runner.send(:action_succeeded?, result)).to be(false)
    end

    it "preserves the verified byte size returned by the sandbox provider" do
      allow(Workspaces::Provider).to receive(:write_file)
        .with(workspace, args["path"], args["content"])
        .and_return({ ok: true, path: args["path"], bytes_written: args["content"].bytesize })

      result = runner.send(:dispatch_tool_call, "workspace_write_file", args)

      expect(result[:ok]).to be(true)
      expect(result[:bytes_written]).to eq(args["content"].bytesize)
    end
  end
end
