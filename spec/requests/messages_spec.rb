# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe "Messages", type: :request do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    # The streaming job performs real agent LLM calls — out of scope here.
    allow(AgentStreamJob).to receive(:perform_later).and_return(true)
  end

  describe "POST /conversations/:id/messages (turbo path)" do
    it "stores the client_request_id in message.metadata so the browser can dedupe" do
      api_login(user)
      cid = "11111111-2222-3333-4444-555555555555"

      post conversation_messages_path(conversation),
           params: { message: { content: "hello", client_request_id: cid } },
           headers: api_headers

      expect(response.status).to be_in([ 200, 201, 302 ])
      msg = conversation.messages.where(role: "user").order(:created_at).last
      expect(msg.metadata).to include("client_request_id" => cid)
    end

    it "leaves metadata untouched when client_request_id is absent" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "hello" } },
           headers: api_headers

      msg = conversation.messages.where(role: "user").order(:created_at).last
      expect(msg.metadata).not_to have_key("client_request_id")
    end

    it "ignores blank client_request_id values (no empty-string metadata key)" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "hello", client_request_id: "" } },
           headers: api_headers

      msg = conversation.messages.where(role: "user").order(:created_at).last
      expect(msg.metadata).not_to have_key("client_request_id")
    end

    it "renders the user message partial with data-client-request-id so the browser can reconcile" do
      api_login(user)
      cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      post conversation_messages_path(conversation),
           params: { message: { content: "hello", client_request_id: cid } },
           headers: api_headers

      msg = conversation.messages.where(role: "user").order(:created_at).last
      html = ApplicationController.render(partial: "messages/message", locals: { message: msg })

      expect(html).to include(%(data-client-request-id="#{cid}"))
      expect(html).to include(%(data-user-message="#{msg.id}"))
    end
  end

  describe "active-turn admission" do
    before do
      conversation.messages.create!(role: "assistant", content: "", metadata: {
        "streaming" => true, "stream_started_at" => Time.current.utc.iso8601, "request_id" => "active-request"
      })
    end

    it "returns an accepted queued follow-up without starting a second job" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "After you", client_request_id: "queued-1" } }, headers: api_headers

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)).to include("admission" => "queued", "queued_count" => 1,
        "background_task_count" => 1)
      expect(conversation.messages.where(role: "user").count).to eq(0)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "accepts explicit steering separately from the follow-up queue" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "Change approach", admission: "steer" } }, headers: api_headers

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)["admission"]).to eq("steering")
      expect(conversation.reload.metadata["m18_steering"].first["content"]).to eq("Change approach")
      expect(conversation.metadata["m18_followups"]).to be_nil
    end

    it "renders the queue-limit reason while leaving the submitted draft untouched" do
      api_login(user)
      Conversations::TurnAdmission::MAX_PENDING.times do |index|
        conversation.metadata["m18_followups"] ||= []
        conversation.metadata["m18_followups"] << { "content" => "Pending #{index}" }
      end
      conversation.save!

      post conversation_messages_path(conversation),
           params: { message: { content: "Preserve this exact draft" } },
           headers: api_headers.merge("Accept" => "text/vnd.turbo-stream.html")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Too many waiting messages")
      expect(response.body).to include("Your draft is preserved")
      expect(conversation.reload.metadata["m18_followups"].size).to eq(Conversations::TurnAdmission::MAX_PENDING)
    end

    it "uses the same queue semantics for the versioned API" do
      api_login(user)

      post api_v1_conversation_messages_path(conversation),
           params: { content: "API follow-up", client_request_id: "api-queued", admission: "queue" },
           headers: api_headers

      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)).to include("admission" => "queued", "message" => nil, "queued_count" => 1)
      expect(conversation.messages.where(role: "user").count).to eq(0)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "rejects a foreign conversation before admitting any content" do
      api_login(user)
      foreign = create(:conversation)

      post conversation_messages_path(foreign),
           params: { message: { content: "Cross-tenant" } }, headers: api_headers

      expect(response).to have_http_status(:not_found)
      expect(foreign.messages.count).to eq(0)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
