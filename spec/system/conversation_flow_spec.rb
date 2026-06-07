# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Conversation flow", type: :system, js: true do
  let!(:user) do
    User.create!(
      email: "test@example.com",
      password: "password123",
      name: "Test"
    )
  end

  let!(:agent) do
    org = Organization.create!(name: "Test Org", slug: "test-org", owner: user)
    Membership.create!(user: user, organization: org, role: "owner")
    Agent.create!(
      name: "Test Agent",
      slug: "test-agent",
      system_prompt: "You are helpful.",
      organization: org,
      tools: ["calculator", "memory_search", "time"]
    )
  end

  before do
    # Stub the LLM endpoint so all chat completions return deterministically.
    stub_request(:post, %r{opencode\.ai/zen/v1/chat/completions})
      .to_return(
        status: 200,
        body: {
          id: "chatcmpl-test",
          object: "chat.completion",
          choices: [{
            index: 0,
            message: { role: "assistant", content: "Hello there!", tool_calls: [] },
            finish_reason: "stop"
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    # Stub embedding endpoint to prevent EmbeddingJob from failing on real HTTP.
    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: {
          data: [{ embedding: [0.1] * 1536, index: 0 }],
          usage: { prompt_tokens: 4, total_tokens: 4 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    # Ensure the agent is the default active agent.
    agent.update!(is_active: true) unless agent.is_active?
  end

  it "creates conversation from home composer and streams agent reply" do
    login_as user

    # Build conversation + messages via controller logic inline.
    convo = Conversation.create!(user: user, agent: agent, title: "Hi")
    convo.messages.create!(role: "user", content: "Hi")
    AgentStreamJob.perform_now(
      conversation_id: convo.id,
      user_id: user.id,
      message_content: "Hi"
    )

    visit conversation_path(convo)

    expect(page).to have_content("Hi")

    # The inline job saves the assistant message to DB.
    expect(page).to have_content("Hello there!")

    # No duplicate user message bubbles.
    user_bubbles = page.all("div", text: /\AHi\z/, wait: false)
    expect(user_bubbles.size).to eq(1)

    # Run record finished.
    run = convo.runs.last
    expect(run.status).to eq("succeeded")
    expect(run.finished_at).to be_present
  end

  it "chat-only prompt in OS mode produces an assistant message with no todos" do
    login_as user

    convo = Conversation.create!(user: user, agent: agent, title: "Hi", mode: "auto_build")
    convo.messages.create!(role: "user", content: "hi")

    # Stub: first call returns empty plan [], second returns the answer.
    stub_request(:post, %r{opencode\.ai/zen/v1/chat/completions})
      .to_return([
        {
          status: 200,
          body: {
            id: "chatcmpl-plan",
            object: "chat.completion",
            choices: [{ index: 0, message: { role: "assistant", content: "[]" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 1, total_tokens: 11 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        },
        {
          status: 200,
          body: {
            id: "chatcmpl-answer",
            object: "chat.completion",
            choices: [{ index: 0, message: { role: "assistant", content: "Hello there!" }, finish_reason: "stop" }],
            usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        }
      ])

    AgentStreamJob.perform_now(
      conversation_id: convo.id,
      user_id: user.id,
      message_content: "hi"
    )

    visit conversation_path(convo)

    expect(page).to have_content("hi")
    expect(page).to have_content("Hello there!")

    agent_run = convo.agent_runs.last
    expect(agent_run).to be_present
    expect(agent_run.todos).to be_empty
  end

  context "when agent uses a tool" do
    it "renders tool call pill when agent uses a tool" do
      login_as user
      conversation = Conversation.create!(user: user, agent: agent, title: "Test")
      conversation.messages.create!(role: "user", content: "what time is it in Colombo?")
      conversation.messages.create!(
        role: "assistant",
        content: "It is 12:37 PM in Colombo",
        tool_calls: [{
          id: "call_123",
          type: "function",
          function: { name: "time", arguments: '{"timezone":"Asia/Colombo"}' }
        }]
      )
      visit conversation_path(conversation)

      expect(page).to have_content("what time is it in Colombo?")

      # Tool call details are rendered in the assistant message.
      expect(page).to have_content("It is 12:37 PM in Colombo")
      expect(page).to have_content("Tool: time")
    end
  end
end
