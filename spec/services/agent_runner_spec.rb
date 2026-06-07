# spec/services/agent_runner_spec.rb

require "rails_helper"

RSpec.describe AgentRunner, type: :service do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:opencode_url) { "https://opencode.ai/zen/v1/chat/completions" }

  before do
    Agents::ToolRegistry.register "test_tool",
      description: "Test",
      parameters: { type: "object", properties: {}, required: [] } do |args|
      { ok: true }
    end

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: {
          data: [{ embedding: [0.1] * 1536, index: 0 }],
          usage: { prompt_tokens: 4, total_tokens: 4 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # ── tool_definitions ────────────────────────────────────────────────

  describe "#tool_definitions" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "returns tool names when tools are strings" do
      allow(agent).to receive(:enabled_tools).and_return(["test_tool"])
      expect(runner.tool_definitions).to eq(["test_tool"])
    end

    it "returns tool names when tools are hashes with symbol keys" do
      allow(agent).to receive(:enabled_tools).and_return([{ name: "test_tool", enabled: true }])
      expect(runner.tool_definitions).to eq(["test_tool"])
    end

    it "returns tool names when tools are hashes with string keys" do
      allow(agent).to receive(:enabled_tools).and_return([{ "name" => "test_tool", "enabled" => true }])
      expect(runner.tool_definitions).to eq(["test_tool"])
    end

    it "handles mixed string and hash tools" do
      allow(agent).to receive(:enabled_tools).and_return(["calculator", { name: "time" }])
      result = runner.tool_definitions
      expect(result).to include("calculator", "time")
    end

    it "returns empty array when no tools" do
      allow(agent).to receive(:enabled_tools).and_return([])
      expect(runner.tool_definitions).to eq([])
    end

    it "compacts nil entries" do
      allow(agent).to receive(:enabled_tools).and_return([nil, "calculator"])
      expect(runner.tool_definitions).to eq(["calculator"])
    end
  end

  # ── #run — basic message (no mode, no tools) ─────────────────────────

  describe "#run" do
    it "creates a run and processes the message" do
      stub_request(:post, opencode_url)
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-test",
            object: "chat.completion",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "Hello!" },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      result = runner.run("Hello, how are you?", stream: false)

      expect(result[:content]).to eq("Hello!")
      expect(conversation.messages.count).to eq(1)
      expect(Run.where(conversation: conversation).first.status).to eq("succeeded")
    end

    it "handles tool calls" do
      stub_request(:post, opencode_url)
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-tool",
            object: "chat.completion",
            choices: [{
              index: 0,
              message: {
                role: "assistant",
                content: nil,
                tool_calls: [{
                  id: "call_123",
                  type: "function",
                  function: { name: "calculator", arguments: '{"expression":"2+2"}' }
                }]
              },
              finish_reason: "tool_calls"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        ).then
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-answer",
            object: "chat.completion",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "The answer is 4." },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 20, completion_tokens: 8, total_tokens: 28 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      result = runner.run("What is 2+2?", stream: false)

      expect(result[:content]).to eq("The answer is 4.")
    end

    # ── OS mode: empty plan short-circuit ────────────────────────────

    context "when conversation has an OS mode" do
      let(:conversation) { create(:conversation, user: user, agent: agent, mode: "auto_build") }

      before do
        allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
        allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
        allow_any_instance_of(AgentRun).to receive(:broadcast_reasoning)
      end

      it "short-circuits to execute_tool_loop when generate_plan returns []" do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-plan",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "[]" },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-answer",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Direct answer." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Hi there", stream: false)

        expect(result[:content]).to eq("Direct answer.")
        expect(conversation.agent_runs.last.todos).to be_empty
      end

      it "creates todos and executes them when plan has steps" do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-plan",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: '["Step one", "Step two"]' },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-exec",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Executed." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-exec2",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Done." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Do two things", stream: false)

        agent_run = conversation.agent_runs.last
        expect(agent_run.todos.count).to eq(2)
        expect(agent_run.todos.pluck(:status)).to all(eq("done"))
      end

      it "pauses at manual_plan mode and awaits approval" do
        conversation.update!(mode: "manual_plan")

        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-plan",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: '["Step one"]' },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Do one thing", stream: false)

        expect(result[:content]).to eq("Plan ready — awaiting approval.")
        expect(result[:plan]).to eq(["Step one"])
        expect(conversation.agent_runs.last.status).to eq("planning")
      end

      it "returns empty content on JSON::ParserError in generate_plan" do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-plan",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "not valid json" },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-answer",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Fallback answer." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Bad plan parse", stream: false)

        expect(result[:content]).to eq("Fallback answer.")
      end
    end

    # ── streaming_message: param ─────────────────────────────────────

    context "with streaming_message" do
      let!(:streaming_msg) { conversation.messages.create!(role: "assistant", content: ".") }

      before do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-test",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Streamed response." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "updates the existing streaming message instead of creating a new one" do
        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user, streaming_message: streaming_msg)
        runner.run("Stream test", stream: false)

        expect(streaming_msg.reload.content).to eq("Streamed response.")
        expect(conversation.messages.count).to eq(1)
      end
    end

    # ── model fallback in chat_with_fallback ─────────────────────────

    context "model fallback" do
      it "falls through to the next model when the first fails" do
        stub_request(:post, opencode_url)
          .to_return(status: 500, body: "Internal Server Error").then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-fallback",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Fallback model worked." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Test fallback", stream: false)

        expect(result[:content]).to eq("Fallback model worked.")
      end

      it "raises after all models fail" do
        stub_request(:post, opencode_url)
          .to_return(status: 500, body: "Fail")

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("All fail", stream: false)

        expect(result[:content]).to eq("I encountered an error while processing your request.")
        expect(Run.last.status).to eq("failed")
      end
    end

    # ── tool_call_id fallback ─────────────────────────────────────────

    context "when API omits tool_call_id" do
      it "generates a secure random fallback id" do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-tool",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: nil,
                    type: "function",
                    function: { name: "calculator", arguments: '{"expression":"2+2"}' }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-answer",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Answer after tool." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 20, completion_tokens: 8, total_tokens: 28 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Compute something", stream: false)

        expect(result[:content]).to eq("Answer after tool.")
      end
    end

    # ── non-streaming when tools present ──────────────────────────────

    context "when tools are present" do
      let(:agent) { create(:agent, organization: organization, tools: ["calculator"]) }

      it "uses non-streaming (sync) chat even when stream: true and block given" do
        stub_request(:post, opencode_url)
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-tool",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_1",
                    type: "function",
                    function: { name: "calculator", arguments: '{"expression":"2+2"}' }
                  }]
                },
                finish_reason: "tool_calls"
              }],
              usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          ).then
          .to_return(
            status: 200,
            body: {
              id: "chatcmpl-answer",
              object: "chat.completion",
              choices: [{
                index: 0,
                message: { role: "assistant", content: "Answer after tool." },
                finish_reason: "stop"
              }],
              usage: { prompt_tokens: 20, completion_tokens: 8, total_tokens: 28 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        chunks = []
        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Use tool", stream: true) do |chunk|
          chunks << chunk
        end

        expect(result[:content]).to eq("Answer after tool.")
        expect(chunks).to include(hash_including(type: "tool_call"))
      end
    end

    # ── error handling ────────────────────────────────────────────────

    context "when execute_tool_loop raises" do
      it "returns an error message and fails the run record" do
        stub_request(:post, opencode_url).to_timeout

        runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Trigger error", stream: false)

        expect(result[:content]).to eq("I encountered an error while processing your request.")
        expect(result[:error]).to be_present
        expect(Run.last.status).to eq("failed")
      end
    end

    # ── duplicate message guard ──────────────────────────────────────

    it "does not create extra user messages beyond the one from the controller" do
      conversation.messages.create!(role: "user", content: "Controller created this")

      stub_request(:post, opencode_url)
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-test",
            object: "chat.completion",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "Hello!" },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      runner.run("Should not create another", stream: false)

      user_messages = conversation.messages.where(role: "user")
      expect(user_messages.count).to eq(1)
      expect(user_messages.first.content).to eq("Controller created this")
    end
  end

  # ── resume_plan ─────────────────────────────────────────────────────

  describe "#resume_plan" do
    let(:agent_run) { create(:agent_run, conversation: conversation, mode: "auto_build", status: "executing") }

    before do
      create(:agent_todo, agent_run: agent_run, position: 0, title: "Step one", status: "done")
      create(:agent_todo, agent_run: agent_run, position: 1, title: "Step two", status: "pending")

      allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
      allow_any_instance_of(AgentRun).to receive(:broadcast_reasoning)
    end

    it "skips completed todos and executes pending ones" do
      stub_request(:post, opencode_url)
        .to_return(
          status: 200,
          body: {
            id: "chatcmpl-exec",
            object: "chat.completion",
            choices: [{
              index: 0,
              message: { role: "assistant", content: "Resumed step." },
              finish_reason: "stop"
            }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      runner = AgentRunner.new(agent: agent, conversation: conversation, user: user)
      runner.resume_plan(agent_run, stream: false)

      expect(agent_run.reload.todos.pluck(:status)).to eq(%w[done done])
      expect(agent_run.status).to eq("completed")
    end
  end

  # ── build_system_prompt ─────────────────────────────────────────────

  describe "#build_system_prompt" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "includes the agent system prompt" do
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include(agent.system_prompt)
    end

    it "includes critical context sections" do
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include("Critical Context")
      expect(prompt).to include("Authentication")
      expect(prompt).to include("Message creation")
      expect(prompt).to include("OpenCode proxy")
      expect(prompt).to include("Tools")
      expect(prompt).to include("Agent OS loop")
      expect(prompt).to include("Rails specifics")
      expect(prompt).to include("UI contracts")
    end

    it "includes available tools when agent has tools" do
      allow(agent).to receive(:enabled_tools).and_return(["calculator"])
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include("Available tools")
      expect(prompt).to include("calculator")
    end

    it "excludes tools section when agent has no tools" do
      allow(agent).to receive(:enabled_tools).and_return([])
      prompt = runner.send(:build_system_prompt)
      expect(prompt).not_to include("Available tools")
    end

    it "includes mode context when conversation has a mode" do
      conversation.update!(mode: "auto_build")
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include("Current OS mode: auto_build")
    end

    it "excludes mode context when conversation has no mode" do
      prompt = runner.send(:build_system_prompt)
      expect(prompt).not_to include("Current OS mode")
    end
  end
end
