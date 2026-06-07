require "rails_helper"

RSpec.describe AgentRunner, type: :service do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  describe "#tool_definitions" do
    subject(:runner) { described_class.new(agent: agent, conversation: conversation, user: user) }

    before do
      Agents::ToolRegistry.register "test_tool",
        description: "Test",
        parameters: { type: "object", properties: {}, required: [] } do |args|
        { ok: true }
      end
    end

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

  describe "#run" do
    let(:full_opencode_url) { "https://opencode.ai/zen/v1/chat/completions" }

    before do
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

    it "creates a run and processes the message" do
      stub_request(:post, full_opencode_url)
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
      # First response with tool call.
      stub_request(:post, full_opencode_url)
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
        # Second response with final answer.
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
  end
end
