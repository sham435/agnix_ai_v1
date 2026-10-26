# frozen_string_literal: true

# Phase 4d — AgentRunner plugin wiring: namespaced plugin tools surface to the
# model only while the org keeps a connected + active integration; schemas
# merge registry + catalog shapes; dotted calls route through
# Tools::Dispatcher with the integration pinned in the agent config; and a
# per-message tool selection narrows (never widens) the effective set.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/NamedSubject, RSpec/MultipleMemoizedHelpers, RSpec/DescribeClass, RSpec/MessageSpies, RSpec/StubbedMock

require "rails_helper"

RSpec.describe "AgentRunner plugin wiring", type: :service do
  subject(:runner) { AgentRunner.new(agent: agent, conversation: conversation, user: user) }

  let(:organization) { create(:organization) }
  let(:user) { create(:user) }
  let(:integration) do
    create(:tool_integration, organization: organization, provider: "slack",
                              credentials: { "api_key" => "xoxb-abc" })
  end
  let(:agent) do
    create(
      :agent,
      organization: organization,
      tools: [ "calculator", { "name" => "slack.post_message", "integration_id" => integration.id } ]
    )
  end
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:client) { instance_double(Llm::Client) }

  before do
    allow(agent).to receive(:llm_client).and_return(client)
  end

  describe "surfacing gate" do
    it "keeps plugin tools whose provider is connected and active" do
      expect(runner.tool_definitions).to contain_exactly("calculator", "slack.post_message")
    end

    it "drops plugin tools when the integration is paused" do
      integration.update!(is_active: false)
      expect(runner.tool_definitions).to eq([ "calculator" ])
    end

    it "drops plugin tools when the row was deleted entirely" do
      integration.destroy
      expect(runner.tool_definitions).to eq([ "calculator" ])
    end

    it "drops unknown dotted names outright — nothing executes them" do
      agent.update!(tools: [ "calculator", "slack.fly_me" ])
      expect(runner.tool_definitions).to eq([ "calculator" ])
    end

    it "keeps plain registry tools untouched" do
      agent.update!(tools: [ "calculator", "time" ])
      expect(runner.tool_definitions).to contain_exactly("calculator", "time")
    end
  end

  describe "schema merge" do
    it "emits registry and catalog schemas side by side" do
      schemas = runner.send(:build_tool_schemas)
      names = schemas.map { |s| s[:name] }
      expect(names).to include("calculator", "slack.post_message")

      plugin = schemas.find { |s| s[:name] == "slack.post_message" }
      expect(plugin[:description]).to include("Slack channel")
      expect(plugin[:parameters][:type]).to eq("object")
      expect(plugin[:parameters][:required]).to include("channel", "text")
    end
  end

  describe "per-message tool selection" do
    it "narrows the agent set to the message's metadata tools" do
      selection = conversation.messages.create!(role: "user", content: "hi",
                                                metadata: { "tools" => [ "calculator" ] })
      scoped = AgentRunner.new(agent: agent, conversation: conversation, user: user,
                                                source_message: selection)
      expect(scoped.tool_definitions).to eq([ "calculator" ])
    end

    it "ignores selected names the agent does not have (never widens)" do
      selection = conversation.messages.create!(role: "user", content: "hi",
                                                metadata: { "tools" => [ "memory_search", "nope" ] })
      scoped = AgentRunner.new(agent: agent, conversation: conversation, user: user,
                                                source_message: selection)
      expect(scoped.tool_definitions).to eq([])
    end

    it "leaves the agent config untouched when metadata has no tools key" do
      selection = conversation.messages.create!(role: "user", content: "hi",
                                                metadata: { "client_request_id" => "x" })
      scoped = AgentRunner.new(agent: agent, conversation: conversation, user: user,
                                                source_message: selection)
      expect(scoped.tool_definitions).to contain_exactly("calculator", "slack.post_message")
    end
  end

  describe "dispatch routing" do
    it "sends dotted calls to the dispatcher with the pinned integration and org" do
      allow(client).to receive(:chat).and_return(
        {
          content: nil,
          tool_calls: [ { "id" => "c1", "type" => "function",
                          "function" => { "name" => "slack.post_message",
                                          "arguments" => { channel: "#general", text: "hi" }.to_json } } ],
          tokens: 4
        },
        { content: "posted", tool_calls: [], tokens: 2 }
      )
      expect(Tools::Dispatcher).to receive(:call)
        .with("slack.post_message",
              arguments: { "channel" => "#general", "text" => "hi" },
              organization: organization,
              integration_id: integration.id,
              context: hash_including(user_id: user.id, conversation_id: conversation.id))
        .and_return({ ok: true, provider: "slack", message_id: "1.1" })

      result = runner.run("tell the team", stream: false)
      expect(result[:content]).to eq("posted")
    end

    it "keeps plain tools on the native registry path" do
      allow(client).to receive(:chat).and_return(
        {
          content: nil,
          tool_calls: [ { "id" => "c2", "type" => "function",
                          "function" => { "name" => "calculator",
                                          "arguments" => { expression: "2+2" }.to_json } } ],
          tokens: 4
        },
        { content: "4", tool_calls: [], tokens: 1 }
      )
      expect(Agents::ToolRegistry).to receive(:execute)
        .with("calculator", { "expression" => "2+2" }, hash_including(user_id: user.id))
        .and_return({ ok: true, answer: 4 })
      expect(Tools::Dispatcher).not_to receive(:call)

      runner.run("math", stream: false)
    end

    it "passes nil integration_id for string-shaped plugin entries" do
      agent.update!(tools: [ "slack.post_message" ])
      allow(client).to receive(:chat).and_return(
        {
          content: nil,
          tool_calls: [ { "id" => "c3", "type" => "function",
                          "function" => { "name" => "slack.post_message",
                                          "arguments" => { channel: "#g", text: "t" }.to_json } } ],
          tokens: 1
        },
        { content: "done", tool_calls: [], tokens: 1 }
      )
      expect(Tools::Dispatcher).to receive(:call) do |name, **opts|
        expect(name).to eq("slack.post_message")
        expect(opts[:integration_id]).to be_nil
        { ok: true }
      end

      runner.run("post", stream: false)
    end
  end
end
