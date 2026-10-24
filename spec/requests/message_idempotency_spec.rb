# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

# A duplicate POST carrying the same client_request_id must never create a
# second user message or enqueue a second streaming run — this is the backend
# half of the in-flight guard. The client also blocks duplicate submits, but
# the server is the authoritative safety net (spec §1, §4).
RSpec.describe "Message send idempotency", type: :request do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before { allow(AgentStreamJob).to receive(:perform_later).and_return(true) }

  it "creates exactly one message and one run for a repeated client_request_id" do
    api_login(user)
    cid = "88888888-1111-2222-3333-444444444444"

    2.times do
      post conversation_messages_path(conversation),
           params: { message: { content: "wb.pdf — extract text", client_request_id: cid } },
           headers: api_headers
      expect(response.status).to be_in([ 200, 201, 302 ])
    end

    user_msgs = conversation.messages.where(role: "user")
    expect(user_msgs.count).to eq(1)
    expect(user_msgs.last.metadata).to include("client_request_id" => cid)
    # The run is enqueued once; the duplicate send acknowledges without
    # re-enqueueing.
    expect(AgentStreamJob).to have_received(:perform_later).once
  end

  it "passes the request_id through to the streaming job" do
    api_login(user)
    cid = "99999999-1111-2222-3333-444444444444"

    post conversation_messages_path(conversation),
         params: { message: { content: "hello", client_request_id: cid } },
         headers: api_headers

    expect(AgentStreamJob).to have_received(:perform_later).with(
      hash_including(request_id: cid)
    )
  end

  it "does not dedupe sends without a client_request_id (distinct messages)" do
    api_login(user)

    2.times do
      post conversation_messages_path(conversation),
           params: { message: { content: "no cid" } },
           headers: api_headers
    end

    expect(conversation.messages.where(role: "user").count).to eq(2)
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
