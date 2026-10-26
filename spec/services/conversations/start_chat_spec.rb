# spec/services/conversations/start_chat_spec.rb

# Phase 5b — The shared chat-startup path. This is the placeholder contract the
# master prompt forbids drifting: user message, then an assistant row flagged
# streaming with a request_id that the queued job must reuse. Job is stubbed
# because the test environment runs ActiveJob inline.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock

require "rails_helper"

RSpec.describe Conversations::StartChat, type: :service do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }

  before { allow(AgentStreamJob).to receive(:perform_later) }

  it "opens an empty conversation when there is no first message" do
    conversation = described_class.call(user: user, agent: agent, title: "Scratch space")

    expect(conversation).to be_persisted
    expect(conversation.agent).to eq(agent)
    expect(conversation.title).to eq("Scratch space")
    expect(conversation.messages.count).to eq(0)
    expect(AgentStreamJob).not_to have_received(:perform_later)
  end

  it "treats whitespace-only content as no content" do
    conversation = described_class.call(user: user, agent: agent, content: "   ")

    expect(conversation.messages.count).to eq(0)
    expect(conversation.title.to_s.strip).to eq("")
    expect(AgentStreamJob).not_to have_received(:perform_later)
  end

  it "seeds the user message plus the streaming assistant placeholder" do
    conversation = described_class.call(user: user, agent: agent, content: "Explain RTL layout in CSS")

    user_row = conversation.messages.find_by(role: "user")
    placeholder = conversation.messages.find_by(role: "assistant")
    expect(conversation.messages.count).to eq(2)
    expect(user_row.content).to eq("Explain RTL layout in CSS")
    expect(placeholder).to be_present
    expect(placeholder.content).to eq("")
    expect(placeholder.metadata["streaming"]).to be(true)
    expect(placeholder.metadata["request_id"]).to match(/\A[\h-]{36}\z/)
    expect(Time.zone.parse(placeholder.metadata["stream_started_at"])).to be_within(5.seconds).of(Time.current)
  end

  it "hands the placeholder request_id to the streaming job" do
    conversation = described_class.call(user: user, agent: agent, content: "Draft a subject line")
    request_id = conversation.messages.find_by(role: "assistant").metadata["request_id"]

    expect(AgentStreamJob).to have_received(:perform_later).with(
      conversation_id: conversation.id,
      user_id: user.id,
      message_content: "Draft a subject line",
      request_id: request_id
    )
  end

  it "derives the title from content, truncated to 50 characters" do
    short = described_class.call(user: user, agent: agent, content: "Hello there")
    expect(short.title).to eq("Hello there")

    long = "quantum " * 20
    truncated = described_class.call(user: user, agent: agent, content: long)
    expect(truncated.title.length).to eq(50)
    expect(truncated.title).to eq("#{long[0, 47]}...")
  end

  it "lets an explicit title win over the content-derived one" do
    conversation = described_class.call(
      user: user,
      agent: agent,
      content: "Summarize these notes",
      title: "New conversation with Meeting Notes"
    )

    expect(conversation.title).to eq("New conversation with Meeting Notes")
    expect(conversation.messages.find_by(role: "user").content).to eq("Summarize these notes")
  end
end
