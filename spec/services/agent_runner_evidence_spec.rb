# frozen_string_literal: true

require "rails_helper"

# Regression specs for the school-build-run false-success bug (task
# shams-agentic-os): plan steps were marked "done" on responses that executed
# NO tool action at all — a text-only apology, or the max-iterations fallback.
# Evidence gating: a step completes only with executed actions and no error /
# iteration exhaustion. write_file additionally verifies bytes on disk.
RSpec.describe AgentRunner, type: :service do
  let(:organization) { create(:organization) }
  let(:agent) { create(:agent) }
  let(:user) { create(:user) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:client) { instance_double(Llm::Client) }

  before do
    allow(agent).to receive(:llm_client).and_return(client)
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

      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      runner.resume_plan(agent_run, stream: false)

      todo = agent_run.reload.todos.first
      expect(todo.status).to eq("failed")
      expect(todo.result.to_s).to include("No tool action was executed")
      # The assistant apology is preserved in the conversation, not lost.
      expect(conversation.messages.assistant.map(&:content).join).to include("no shell access")
    end

    it "marks a step FAILED when the loop hit the iteration limit (incomplete marker)" do
      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
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
      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      allow(runner).to receive(:execute_tool_loop).and_return(
        { content: "wrote 3 files and ran tests", tool_calls: [], tokens: 0, actions: 5 }
      )

      result = runner.send(:execute_step, "Write the source files", false)

      expect(result[:ok]).to be(true)
      expect(result[:output]).to eq("wrote 3 files and ran tests")
    end

    it "fails a step whose loop raised an error even when actions executed" do
      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      allow(runner).to receive(:execute_tool_loop).and_return(
        { content: "boom", error: "total loss", tool_calls: [], tokens: 0, actions: 2 }
      )

      result = runner.send(:execute_step, "Install dependencies", false)

      expect(result[:ok]).to be(false)
      expect(result[:output]).to include("total loss")
    end
  end

  describe "write_file disk verification" do
    after do
      [ "/tmp/shams-evidence" ].each { |dir| FileUtils.remove_entry(dir) rescue nil }
    end

    let(:tool) { Agents::ToolRegistry.get("write_file") }

    it "fails when the executor claims success but no bytes reach the disk" do
      allow(Agents::OsExecutor).to receive(:write_file).and_return({ ok: true, path: "/nonexistent/void/models.py" })

      result = Agents::ToolRegistry.execute("write_file", { "path" => "/nonexistent/void/models.py", "content" => "class Student" })

      expect(result[:ok]).to be(false)
      expect(result[:error]).to include("write verification failed")
    end

    it "succeeds with a real write and reports the verified byte size" do
      FileUtils.mkdir_p("/tmp/shams-evidence")
      path = "/tmp/shams-evidence/models.py"
      result = Agents::ToolRegistry.execute("write_file", { "path" => path, "content" => "class Student:\n    pass\n" })

      expect(result[:ok]).to be(true)
      expect(result[:bytes_written]).to eq(File.size(result[:path]))
    end
  end
end
