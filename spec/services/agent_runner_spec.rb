# spec/services/agent_runner_spec.rb

# Integration-style narrative specs for the runner: several assertions per
# example and spy-based tool registry captures are intentional here.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/AnyInstance, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe AgentRunner, type: :service do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:client) { instance_double(Llm::Client) }

  before do
    allow(agent).to receive(:llm_client).and_return(client)

    Agents::ToolRegistry.register "test_tool",
      description: "Test",
      parameters: { type: "object", properties: {}, required: [] } do |args|
      { ok: true }
    end

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: {
          data: [ { embedding: [ 0.1 ] * 1536, index: 0 } ],
          usage: { prompt_tokens: 4, total_tokens: 4 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  # ── tool_definitions ────────────────────────────────────────────────

  describe "#tool_definitions" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "returns tool names when tools are strings" do
      allow(agent).to receive(:enabled_tools).and_return([ "test_tool" ])
      expect(runner.tool_definitions).to eq([ "test_tool" ])
    end

    it "returns tool names when tools are hashes with symbol keys" do
      allow(agent).to receive(:enabled_tools).and_return([ { name: "test_tool", enabled: true } ])
      expect(runner.tool_definitions).to eq([ "test_tool" ])
    end

    it "returns tool names when tools are hashes with string keys" do
      allow(agent).to receive(:enabled_tools).and_return([ { "name" => "test_tool", "enabled" => true } ])
      expect(runner.tool_definitions).to eq([ "test_tool" ])
    end

    it "handles mixed string and hash tools" do
      allow(agent).to receive(:enabled_tools).and_return([ "calculator", { name: "time" } ])
      result = runner.tool_definitions
      expect(result).to include("calculator", "time")
    end

    it "returns empty array when no tools" do
      allow(agent).to receive(:enabled_tools).and_return([])
      expect(runner.tool_definitions).to eq([])
    end

    it "compacts nil entries" do
      allow(agent).to receive(:enabled_tools).and_return([ nil, "calculator" ])
      expect(runner.tool_definitions).to eq([ "calculator" ])
    end

    it "resolves OS-mode read_file against the registry (rename no longer drops it)" do
      allow(agent).to receive(:enabled_tools).and_return([])
      os_conversation = create(:conversation, user: user, agent: agent, mode: "auto_build")
      os_runner = described_class.new(agent: agent, conversation: os_conversation, user: user)

      names = os_runner.tool_definitions
      expect(names).to include("read_file")
      expect(Agents::ToolRegistry.get("read_file")).to be_present
    end
  end

  # ── capability-aware chat tool surfacing (Phase C) ──────────────────

  describe "capability-aware tool surfacing" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    def attach_file_to_conversation(target = conversation)
      asset = create(:asset, user: user, filename: "README.md")
      message = target.messages.create!(role: "user", content: "Look at my file")
      message.message_attachments.create!(asset: asset)
      asset
    end

    it "keeps plain chat tool-free without attachments (streaming path unchanged)" do
      allow(agent).to receive(:enabled_tools).and_return([])
      expect(runner.tool_definitions).to eq([])
    end

    it "surfaces generate_image only once the image_generation capability is enabled" do
      allow(agent).to receive(:enabled_tools).and_return([])
      expect(runner.tool_definitions).not_to include("generate_image")

      allow(Capabilities::Registry).to receive(:available?).and_call_original
      allow(Capabilities::Registry).to receive(:available?).with("image_generation").and_return(true)
      expect(runner.tool_definitions).to eq(%w[generate_image])
    end

    it "surfaces read-only asset tools when the conversation carries attachments" do
      allow(agent).to receive(:enabled_tools).and_return([])
      attach_file_to_conversation

      expect(runner.tool_definitions).to eq(%w[read_asset list_assets])
    end

    it "respects per-capability honest states when surfacing asset tools" do
      allow(agent).to receive(:enabled_tools).and_return([])
      attach_file_to_conversation
      allow(Capabilities::Registry).to receive(:available?).and_call_original
      allow(Capabilities::Registry).to receive(:available?).with("file_extraction").and_return(false)

      expect(runner.tool_definitions).to eq(%w[list_assets])
    end

    it "filters capability-backed configured tools whose capability is unavailable" do
      allow(agent).to receive(:enabled_tools).and_return([ "web_search" ])
      allow(Capabilities::Registry).to receive(:available?).and_call_original
      allow(Capabilities::Registry).to receive(:available?).with("web_search").and_return(false)

      expect(runner.tool_definitions).to eq([])
    end

    it "keeps configured tools whose capability is enabled" do
      allow(agent).to receive(:enabled_tools).and_return([ "web_search" ])
      allow(Capabilities::Registry).to receive(:available?).and_call_original
      allow(Capabilities::Registry).to receive(:available?).with("web_search").and_return(true)

      expect(runner.tool_definitions).to eq(%w[web_search])
    end

    it "adds asset tools to OS-mode conversations with attachments" do
      allow(agent).to receive(:enabled_tools).and_return([])
      os_conversation = create(:conversation, user: user, agent: agent, mode: "auto_build")
      attach_file_to_conversation(os_conversation)
      os_runner = described_class.new(agent: agent, conversation: os_conversation, user: user)

      names = os_runner.tool_definitions
      expect(names).to include("run_command", "write_file", "read_asset", "list_assets")
    end

    it "passes the acting user into executor context for ownership checks" do
      allow(agent).to receive(:enabled_tools).and_return([ "test_tool" ])
      allow(Agents::ToolRegistry).to receive(:execute).and_return({ ok: true })
      allow(client).to receive(:chat).and_return(
        {
          content: nil,
          tool_calls: [ {
            id: "call_ctx",
            type: "function",
            function: { name: "test_tool", arguments: "{}" }
          } ],
          tokens: 10
        },
        { content: "done", tool_calls: [], tokens: 12 }
      )

      runner.run("use the tool", stream: false)

      expect(Agents::ToolRegistry).to have_received(:execute)
        .with("test_tool", anything, hash_including(user_id: user.id, user: user))
    end
  end

  # ── provider/model/API-key delegation ───────────────────────────────

  describe "provider delegation to agent.llm_client" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "uses agent.llm_client for the reply (no direct Llm::Client construction)" do
      expect(agent).to receive(:llm_client).and_return(client).at_least(:once)
      allow(client).to receive(:chat).and_return(content: "hello", tool_calls: [], tokens: 5)

      result = runner.run("hello", stream: false)

      expect(result[:content]).to eq("hello")
    end

    it "passes tool schemas to the configured agent client" do
      allow(agent).to receive(:enabled_tools).and_return([ "calculator" ])
      expect(agent).to receive(:llm_client).and_return(client).at_least(:once)
      expect(client).to receive(:chat)
        .with(messages: anything, tools: including(hash_including(name: "calculator")))
        .and_return(content: "ok", tool_calls: [], tokens: 3)

      runner.run("Use calculator", stream: false)
    end

    it "does not define or reference OpenCode fallback models" do
      expect(described_class.const_defined?(:FALLBACK_MODELS)).to be(false)
      expect(described_class.instance_methods).not_to include(:chat_with_fallback)
    end

    it "does not leak provider wiring into the normal-chat system prompt" do
      expect(client).to receive(:chat) do |messages:, tools:|
        system_prompt = messages.first[:content]
        expect(system_prompt).not_to include("Provider:")
        expect(system_prompt).not_to include("agent.llm_client")
        expect(system_prompt).to include(agent.system_prompt)
        { content: "ok", tool_calls: [], tokens: 3 }
      end
      expect(agent).to receive(:llm_client).and_return(client).at_least(:once)

      runner.run("hi", stream: false)
    end
  end

  # ── #run — basic message (no mode, no tools) ─────────────────────────

  describe "#run" do
    it "creates a run and processes the message" do
      allow(client).to receive(:chat)
        .with(messages: anything, tools: anything)
        .and_return(content: "Hello!", tool_calls: [], tokens: 15)

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      result = runner.run("Hello, how are you?", stream: false)

      expect(result[:content]).to eq("Hello!")
      expect(conversation.messages.count).to eq(1)
      expect(Run.where(conversation: conversation).first.status).to eq("succeeded")
    end

    it "handles tool calls" do
      allow(client).to receive(:chat).and_return(
        {
          content: nil,
          tool_calls: [ {
            id: "call_123",
            type: "function",
            function: { name: "calculator", arguments: '{"expression":"2+2"}' }
          } ],
          tokens: 10
        },
        { content: "The answer is 4.", tool_calls: [], tokens: 20 }
      )

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
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
        allow(client).to receive(:chat).and_return(
          { content: "[]", tool_calls: [], tokens: 5 },
          { content: "Direct answer.", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Hi there", stream: false)

        expect(result[:content]).to eq("Direct answer.")
        expect(conversation.agent_runs.last.todos).to be_empty
      end

      it "creates todos and executes them when plan has steps" do
        allow(Agents::ToolRegistry).to receive(:execute).and_return({ ok: true })
        allow(client).to receive(:chat).and_return(
          { content: '["Step one", "Step two"]', tool_calls: [], tokens: 5 },
          { content: nil, tool_calls: [ { id: "call_1", function: { name: "run_command", arguments: "{}" } } ], tokens: 6 },
          { content: "Executed.", tool_calls: [], tokens: 10 },
          { content: nil, tool_calls: [ { id: "call_2", function: { name: "run_command", arguments: "{}" } } ], tokens: 6 },
          { content: "Done.", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Do two things", stream: false)

        agent_run = conversation.agent_runs.last
        expect(agent_run.todos.count).to eq(2)
        # Each step executed at least one real tool action (evidence gating).
        expect(agent_run.todos.pluck(:status)).to all(eq("done"))
      end

      it "finalizes a plan without file targets as completed (output verification runs)" do
        allow(Agents::ToolRegistry).to receive(:execute).and_return({ ok: true })
        allow_any_instance_of(AgentRun).to receive(:broadcast_reasoning)
        allow_any_instance_of(AgentRun).to receive(:broadcast_status)
        allow(client).to receive(:chat).and_return(
          { content: '["Install dependencies"]', tool_calls: [], tokens: 5 },
          { content: nil, tool_calls: [ { id: "call_1", function: { name: "run_command", arguments: "{}" } } ], tokens: 6 },
          { content: "Installed.", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        runner.run("Install deps", stream: false)

        agent_run = conversation.agent_runs.last
        expect(agent_run.reload.status).to eq("completed")
        expect(agent_run.reasoning_steps.map { |s| s["step"] }).to include("Output verification")
      end

      it "marks the run failed when a promised build output never reached disk (no false success)" do
        allow(Agents::ToolRegistry).to receive(:execute).and_return({ ok: true })
        allow_any_instance_of(AgentRun).to receive(:broadcast_reasoning)
        allow_any_instance_of(AgentRun).to receive(:broadcast_status)
        missing_root = "/tmp/shams-runner-verify-#{SecureRandom.hex(4)}-missing"
        allow(client).to receive(:chat).and_return(
          { content: "[\"Write '#{missing_root}/src/app.py'\"]", tool_calls: [], tokens: 5 },
          { content: nil, tool_calls: [ { id: "call_1", function: { name: "write_file", arguments: "{}" } } ], tokens: 6 },
          { content: "Wrote it (allegedly).", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        runner.run("Build the school app", stream: false)

        agent_run = conversation.agent_runs.last
        expect(agent_run.reload.status).to eq("failed")
        todo = agent_run.todos.reload.first
        expect(todo.status).to eq("failed")
        expect(todo.result).to include("Output verification:")
        expect(todo.result).to include(missing_root)
      end

      it "pauses at manual_plan mode and awaits approval" do
        conversation.update!(mode: "manual_plan")

        allow(client).to receive(:chat).and_return(
          { content: '["Step one"]', tool_calls: [], tokens: 5 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Do one thing", stream: false)

        expect(result[:content]).to eq("Plan ready — awaiting approval.")
        expect(result[:plan]).to eq([ "Step one" ])
        expect(conversation.agent_runs.last.status).to eq("planning")
      end

      it "returns empty content on JSON::ParserError in generate_plan" do
        allow(client).to receive(:chat).and_return(
          { content: "not valid json", tool_calls: [], tokens: 5 },
          { content: "Fallback answer.", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Bad plan parse", stream: false)

        expect(result[:content]).to eq("Fallback answer.")
      end
    end

    # ── streaming_message: param ─────────────────────────────────────

    context "with streaming_message" do
      let!(:streaming_msg) { conversation.messages.create!(role: "assistant", content: ".") }

      it "updates the existing streaming message instead of creating a new one" do
        allow(client).to receive(:chat).and_return(
          { content: "Streamed response.", tool_calls: [], tokens: 10 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user, streaming_message: streaming_msg)
        runner.run("Stream test", stream: false)

        expect(streaming_msg.reload.content).to eq("Streamed response.")
        expect(conversation.messages.count).to eq(1)
      end
    end

    # ── error handling: no fallback after the configured client fails ─

    context "when the configured agent client fails" do
      it "reports an error and marks the run as failed (no model fallback)" do
        allow(client).to receive(:chat).and_raise(StandardError, "provider down")
        expect(client).to receive(:chat).once

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Test error", stream: false)

        expect(result[:content]).to eq("I encountered an error while processing your request.")
        expect(result[:error]).to be_present
        expect(Run.last.status).to eq("failed")
      end
    end

    # ── tool_call_id fallback ─────────────────────────────────────────

    context "when API omits tool_call_id" do
      it "generates a secure random fallback id" do
        allow(client).to receive(:chat).and_return(
          {
            content: nil,
            tool_calls: [ {
              id: nil,
              type: "function",
              function: { name: "calculator", arguments: '{"expression":"2+2"}' }
            } ],
            tokens: 10
          },
          { content: "Answer after tool.", tool_calls: [], tokens: 20 }
        )

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Compute something", stream: false)

        expect(result[:content]).to eq("Answer after tool.")
      end
    end

    # ── streaming is used even when tools are present ─────────────────

    context "when tools are present" do
      let(:agent) { create(:agent, organization: organization, tools: [ "calculator" ]) }

      it "streams incremental status + content events and still emits tool_call events" do
        # Regression guard for the "no real-time response" bug: the old code
        # fell back to a fully-buffered sync call whenever tools were present,
        # so nothing streamed. The agentic path must now stream even with tools,
        # forward throttled status events (never raw reasoning), surface genuine
        # content deltas, and still report tool activity — in order.
        call_index = 0
        allow(client).to receive(:stream_chat) do |_kwargs, &blk|
          call_index += 1
          if call_index == 1
            # Reasoning-only turn that then requests a tool: yield a reasoning
            # delta (→ status:"thinking"), never its text as content.
            blk&.call("pondering", "pondering", [], "reasoning")
            {
              content: "",
              tool_calls: [ {
                id: "call_1",
                type: "function",
                function: { name: "calculator", arguments: '{"expression":"2+2"}' }
              } ],
              tokens: 10
            }
          else
            # Final answer turn: stream genuine content deltas.
            blk&.call("Answer ", "Answer ", [], "content")
            blk&.call("after tool.", "Answer after tool.", [], "content")
            { content: "Answer after tool.", tool_calls: [], tokens: 20 }
          end
        end

        chunks = []
        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Use tool", stream: true) do |chunk|
          chunks << chunk
        end

        expect(result[:content]).to eq("Answer after tool.")

        # Connecting heartbeat first, then thinking, then a tool call, then
        # generating + the incremental content deltas.
        types = chunks.map { |c| c[:type] }
        expect(types).to include("status")
        expect(chunks).to include(hash_including(type: "status", phase: "connecting"))
        expect(chunks).to include(hash_including(type: "status", phase: "thinking"))
        expect(chunks).to include(hash_including(type: "status", phase: "generating"))
        expect(chunks).to include(hash_including(type: "tool_call", tool: "calculator"))
        expect(chunks).to include(hash_including(type: "content_delta", text: "Answer "))
        expect(chunks).to include(hash_including(type: "content_delta", text: "after tool."))

        # CRITICAL: no raw reasoning text ever leaves the runner.
        expect(chunks.none? { |c| c.to_s.include?("pondering") }).to be(true)
        deltas = chunks.select { |c| c[:type] == "content_delta" }.map { |c| c[:text] }.join
        expect(deltas).to eq("Answer after tool.")
      end

      it "emits a failed status when the provider raises mid-run" do
        allow(client).to receive(:stream_chat).and_raise(Llm::OpenaiAdapter::LlmError.new("provider down"))

        chunks = []
        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Blow up", stream: true) { |chunk| chunks << chunk }

        expect(result[:error]).to be_present
        expect(chunks).to include(hash_including(type: "status", phase: "failed"))
      end
    end

    # ── error handling ────────────────────────────────────────────────

    context "when execute_tool_loop raises" do
      it "returns an error message and fails the run record" do
        allow(client).to receive(:chat).and_raise(StandardError, "boom")

        runner = described_class.new(agent: agent, conversation: conversation, user: user)
        result = runner.run("Trigger error", stream: false)

        expect(result[:content]).to eq("I encountered an error while processing your request.")
        expect(result[:error]).to be_present
        expect(Run.last.status).to eq("failed")
      end
    end

    # ── duplicate message guard ──────────────────────────────────────

    it "does not create extra user messages beyond the one from the controller" do
      conversation.messages.create!(role: "user", content: "Controller created this")

      allow(client).to receive(:chat).and_return(
        { content: "Hello!", tool_calls: [], tokens: 15 }
      )

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      runner.run("Should not create another", stream: false)

      user_messages = conversation.messages.where(role: "user")
      expect(user_messages.count).to eq(1)
      expect(user_messages.first.content).to eq("Controller created this")
    end
  end

  # ── chat_for_plan: uses the configured agent client ─────────────────

  describe "#chat_for_plan" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "delegates to agent.llm_client and returns the raw content" do
      expect(agent).to receive(:llm_client).and_return(client)
      expect(client).to receive(:chat)
        .with(messages: [ hash_including(role: "user", content: "Build a thing") ])
        .and_return(content: '["Step one"]', tool_calls: [], tokens: 5)

      expect(runner.send(:chat_for_plan, "Build a thing")).to eq('["Step one"]')
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

    it "skips completed todos and fails pending ones that took no tool action (evidence gating)" do
      allow(client).to receive(:chat).and_return(
        { content: "Resumed step.", tool_calls: [], tokens: 10 }
      )

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      runner.resume_plan(agent_run, stream: false)

      # Evidence gating: a text-only reply executes no tool action, so the
      # pending step can no longer be marked done.
      expect(agent_run.reload.todos.pluck(:status)).to eq(%w[done failed])
      expect(agent_run.todos.find_by(title: "Step two").result).to include("No tool action was executed")
      expect(agent_run.status).to eq("completed")
    end

    it "completes a pending step when the loop executes real tool actions" do
      allow(Agents::ToolRegistry).to receive(:execute).and_return({ ok: true })
      allow(client).to receive(:chat).and_return(
        { content: nil, tool_calls: [ { id: "call_1", function: { name: "run_command", arguments: "{}" } } ], tokens: 10 },
        { content: "Wrote the file and verified it.", tool_calls: [], tokens: 10 }
      )

      runner = described_class.new(agent: agent, conversation: conversation, user: user)
      runner.resume_plan(agent_run, stream: false)

      expect(agent_run.reload.todos.pluck(:status)).to eq(%w[done done])
    end
  end

  # ── build_system_prompt ─────────────────────────────────────────────

  describe "#build_system_prompt" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    it "includes the agent system prompt" do
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include(agent.system_prompt)
    end

    it "excludes critical context sections for normal chat" do
      prompt = runner.send(:build_system_prompt)
      expect(prompt).not_to include("Constraints:")
      expect(prompt).not_to include("Provider: anthropic")
      expect(prompt).not_to include("Rails 8.1.3")
    end

    it "includes critical context sections in OS mode" do
      conversation.update!(mode: "auto_build")
      prompt = runner.send(:build_system_prompt)
      expect(prompt).to include("Constraints:")
      expect(prompt).to include("Auth:")
      expect(prompt).to include("Controller creates user Message")
      expect(prompt).to include("Provider: anthropic")
      expect(prompt).to include("Model: claude-sonnet-4-6")
      expect(prompt).to include("agent.llm_client")
      expect(prompt).to include("agent.enabled_tools")
      expect(prompt).to include("generate_plan")
      expect(prompt).to include("Rails 8.1.3")
      expect(prompt).to include("data-streaming-content")
    end

    it "includes available tools when agent has tools" do
      allow(agent).to receive(:enabled_tools).and_return([ "calculator" ])
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
