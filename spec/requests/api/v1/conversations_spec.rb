# frozen_string_literal: true

# Integration-style specs for the API v1 conversation lifecycle: the list a
# client renders and POST /api/v1/conversations, the endpoint that lets a
# client start a chat. The create path is asserted against the same startup
# contract the web composer uses (Conversations::StartChat), because that
# shared path is the whole point of routing clients through it.
# rubocop:disable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe "API v1 conversations", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let!(:membership) { create(:membership, user: user, organization: organization, role: "owner") }
  let(:other_organization) { create(:organization) }
  let(:agent) { create(:agent, organization: organization, name: "Code Writer") }

  before { allow(AgentStreamJob).to receive(:perform_later) }

  describe "GET /api/v1/conversations" do
    it "requires authentication" do
      get "/api/v1/conversations"
      expect(response).to have_http_status(401)
    end

    it "lists the caller's active conversations newest first, with their agent" do
      api_login(user)
      create(:conversation, user: user, agent: agent, title: "older", status: "active")
      create(:conversation, user: user, agent: agent, title: "newer", status: "active")
      create(:conversation, user: user, agent: agent, title: "archived one", status: "archived")
      create(:conversation, user: create(:user), agent: agent, title: "someone else's")

      get "/api/v1/conversations", headers: api_headers
      expect(response).to have_http_status(:ok)

      body = JSON.parse(response.body)
      expect(body.map { |c| c["title"] }).to eq([ "newer", "older" ])
      expect(body.first["agent"]["name"]).to eq("Code Writer")
    end
  end

  describe "POST /api/v1/conversations" do
    it "requires authentication" do
      post "/api/v1/conversations", params: { agent_id: agent.id }, headers: api_headers
      expect(response).to have_http_status(401)
    end

    it "starts an empty conversation when no content is sent, and queues nothing" do
      api_login(user)

      expect do
        post "/api/v1/conversations", params: { agent_id: agent.id }, headers: api_headers
      end.to change(Conversation, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["id"]).to be_present
      expect(body["agent_id"]).to eq(agent.id)
      expect(Conversation.find(body["id"]).messages.count).to eq(0)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "reuses the web startup path: title, user message, streaming placeholder, job carrying that request_id" do
      api_login(user)

      post "/api/v1/conversations",
           params: { agent_id: agent.id, content: "wanna update to rails 8.2" }, headers: api_headers
      expect(response).to have_http_status(:created)

      conversation = Conversation.find(JSON.parse(response.body)["id"])
      expect(conversation.title).to eq("wanna update to rails 8.2")
      expect(conversation.messages.where(role: "user").count).to eq(1)

      placeholder = conversation.messages.where(role: "assistant").last
      expect(placeholder).to be_present
      expect(placeholder.content.to_s).to eq("")
      expect(placeholder.streaming?).to be(true)
      request_id = placeholder.metadata["request_id"]
      expect(request_id).to be_present

      expect(AgentStreamJob).to have_received(:perform_later).with(
        hash_including(request_id: request_id, conversation_id: conversation.id)
      )

      # And the chat is readable through the endpoint the client polls, with the
      # placeholder visible so it knows a reply is still arriving.
      get "/api/v1/conversations/#{conversation.id}", headers: api_headers
      expect(response).to have_http_status(:ok)
      messages = JSON.parse(response.body)["messages"]
      expect(messages.map { |m| m["role"] }).to eq([ "user", "assistant" ])
      expect(messages.last["metadata"]["streaming"]).to be(true)
    end

    it "never starts a chat with an agent from another organization" do
      api_login(user)
      foreign = create(:agent, organization: other_organization)

      expect do
        post "/api/v1/conversations", params: { agent_id: foreign.id }, headers: api_headers
      end.not_to change(Conversation, :count)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to eq("Agent not found.")
    end

    it "answers 404 for a missing or malformed agent id instead of raising" do
      api_login(user)

      post "/api/v1/conversations", headers: api_headers
      expect(response).to have_http_status(:not_found)

      post "/api/v1/conversations", params: { agent_id: "not-a-uuid" }, headers: api_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
# rubocop:enable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
