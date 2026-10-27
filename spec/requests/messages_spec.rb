# frozen_string_literal: true

require "rails_helper"

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
      msg = conversation.messages.order(:created_at).last
      expect(msg.metadata).to include("client_request_id" => cid)
    end

    it "leaves metadata untouched when client_request_id is absent" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "hello" } },
           headers: api_headers

      msg = conversation.messages.order(:created_at).last
      expect(msg.metadata).not_to have_key("client_request_id")
    end

    it "ignores blank client_request_id values (no empty-string metadata key)" do
      api_login(user)

      post conversation_messages_path(conversation),
           params: { message: { content: "hello", client_request_id: "" } },
           headers: api_headers

      msg = conversation.messages.order(:created_at).last
      expect(msg.metadata).not_to have_key("client_request_id")
    end

    it "renders the user message partial with data-client-request-id so the browser can reconcile" do
      api_login(user)
      cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      post conversation_messages_path(conversation),
           params: { message: { content: "hello", client_request_id: cid } },
           headers: api_headers

      msg = conversation.messages.order(:created_at).last
      html = ApplicationController.render(partial: "messages/message", locals: { message: msg })

      expect(html).to include(%(data-client-request-id="#{cid}"))
      expect(html).to include(%(data-user-message="#{msg.id}"))
    end
  end
end
