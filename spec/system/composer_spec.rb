# spec/system/composer_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat composer", type: :system, js: true do
  let!(:user) do
    User.create!(email: "composer@example.com", password: "password123", name: "Composer")
  end

  let!(:agent) do
    org = Organization.create!(name: "Composer Org", slug: "composer-org", owner: user)
    Membership.create!(user: user, organization: org, role: "owner")
    Agent.create!(
      name: "Composer Agent",
      slug: "composer-agent",
      system_prompt: "You are helpful.",
      organization: org,
      tools: []
    )
  end

  before do
    stub_request(:post, %r{api\.anthropic\.com/v1/messages})
      .to_return(
        status: 200,
        body: {
          id: "msg_composer",
          type: "message",
          role: "assistant",
          content: [{ type: "text", text: "Hello there!" }],
          model: "claude-sonnet-4-6",
          stop_reason: "end_turn",
          usage: { input_tokens: 10, output_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: {data: [{embedding: [0.1] * 1536, index: 0}], usage: {prompt_tokens: 4, total_tokens: 4}}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
  end

  it "sends the draft with Enter instead of inserting a newline" do
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)

    stub_composer_desktop!
    fill_in "message-input", with: "Hello from Chrome"
    find("#message-input").send_keys(:enter)

    # A successful submit clears the composer (turbo:submit-end -> clear).
    # If Enter had only inserted a newline, the draft would still be there.
    expect(page).to have_field("message-input", with: "", wait: 5)
  end

  it "keeps the draft on a new line when Shift+Enter is pressed" do
    login_as user
    conversation = Conversation.create!(user: user, agent: agent, title: "Composer")
    visit conversation_path(conversation)

    stub_composer_desktop!
    fill_in "message-input", with: "line one"
    find("#message-input").send_keys(%i[shift enter])

    expect(page).to have_field("message-input", with: "line one\n", wait: 5)
  end
end
