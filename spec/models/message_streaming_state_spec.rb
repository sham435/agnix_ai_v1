# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

# Refresh-recovery contract (spec §2): a genuinely in-flight run keeps the
# thinking indicator; a run that died mid-flight stops showing "thinking" once
# its execution window elapses, using the persisted stream_started_at. Legacy
# placeholders with no timestamp stay live for backward compatibility.
RSpec.describe "Message streaming state", type: :model do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  def placeholder(metadata)
    conversation.messages.create!(role: "assistant", content: "", metadata: metadata)
  end

  it "treats a legacy placeholder (no stamp) as live, never stale" do
    m = placeholder({ "streaming" => true })
    expect(m).to be_streaming
    expect(m).not_to be_stale_streaming
  end

  it "keeps a freshly stamped placeholder live" do
    m = placeholder({ "streaming" => true, "stream_started_at" => Time.current.utc.iso8601 })
    expect(m).to be_streaming
    expect(m).not_to be_stale_streaming
  end

  it "marks an over-aged placeholder stale so refresh does not hang on thinking" do
    old = (Message::STREAMING_TIMEOUT + 5.seconds).ago.utc.iso8601
    m = placeholder({ "streaming" => true, "stream_started_at" => old })
    expect(m).to be_streaming
    expect(m).to be_stale_streaming
  end

  it "does not flag a finalized message stale" do
    m = conversation.messages.create!(role: "assistant", content: "done", metadata: {})
    expect(m).not_to be_stale_streaming
  end

  it "renders stale placeholders without the perpetual thinking indicator" do
    old = (Message::STREAMING_TIMEOUT + 5.seconds).ago.utc.iso8601
    m = placeholder({ "streaming" => true, "request_id" => "req-stale", "stream_started_at" => old })
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: m })

    expect(html).to include('data-streaming="false"')
    expect(html).to include("data-stale-response-body")
    expect(html).not_to include("[data-thinking-indicator]")
    expect(html).not_to include("Shams AI is thinking")
  end

  it "tags a live placeholder with request_id and the thinking indicator" do
    m = placeholder({ "streaming" => true, "request_id" => "req-live", "stream_started_at" => Time.current.utc.iso8601 })
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: m })

    expect(html).to include(%(data-request-id="req-live"))
    expect(html).to include('data-streaming="true"')
    expect(html).to include("data-thinking-indicator")
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
