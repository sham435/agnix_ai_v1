# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Dashboard new-chat streaming placeholder", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let!(:membership) { create(:membership, user: user, organization: organization, role: "owner") }
  let(:agent) { create(:agent, organization: organization) }

  before { allow(AgentStreamJob).to receive(:perform_later) }

  describe "GET /dashboard" do
    it "redirects signed-out visitors to sign in" do
      get "/dashboard"

      expect(response).to redirect_to(login_path)
    end

    it "renders the conversations home for signed-in users" do
      api_login(user)

      get "/dashboard"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Shams")
    end
  end

  it "selects only an active agent in the signed-in organization" do
    foreign = create(:agent)
    own = agent
    api_login(user)

    get conversations_path

    field = Nokogiri::HTML(response.body).at_css('input[name="agent_id"]')
    expect(field["value"]).to eq(own.id)
    expect(field["value"]).not_to eq(foreign.id)
  end

  it "starts with the organization's default agent when the id is omitted" do
    own = agent
    api_login(user)

    post conversations_path, params: { content: "hello" }, headers: api_headers

    expect(response).to have_http_status(:created)
    expect(Conversation.sole.agent).to eq(own)
  end

  it "never accepts a foreign or inactive agent" do
    foreign = create(:agent)
    inactive = create(:agent, organization: organization, is_active: false)
    api_login(user)

    [ foreign.id, inactive.id ].each do |id|
      post conversations_path, params: { content: "Keep this prompt", agent_id: id }, headers: api_headers
      expect(response).to redirect_to(conversations_path(prompt: "Keep this prompt"))
      expect(Conversation.count).to eq(0)
    end
  end

  it "shows setup rather than submitting a global agent for an empty organization" do
    create(:agent)
    api_login(user)

    get conversations_path

    page = Nokogiri::HTML(response.body)
    expect(page.at_css('input[name="agent_id"]')["value"]).to be_blank
    expect(page.at_css('button[aria-label="Send message"]')["disabled"]).to be_present
    expect(response.body).to include("Set up an agent")
  end

  describe "POST /conversations (home composer) with content" do
    it "provisions an assistant streaming placeholder carrying a request_id" do
      api_login(user)

      post conversations_path,
           params: { content: "hello", agent_id: agent.id },
           headers: api_headers

      convo = Conversation.order(:created_at).last
      expect(convo).to be_present
      expect(convo.messages.where(role: "user").count).to eq(1)

      placeholder = convo.messages.where(role: "assistant").order(:created_at).last
      expect(placeholder).to be_present
      expect(placeholder.content.to_s).to eq("")
      expect(placeholder.streaming?).to be(true)
      expect(placeholder.metadata["request_id"]).to be_present
      # A freshly-stamped placeholder is never stale -> renders live thinking.
      expect(placeholder.stale_streaming?).to be(false)
    end

    it "enqueues AgentStreamJob with the SAME request_id so the job reuses the row" do
      api_login(user)

      post conversations_path,
           params: { content: "hello", agent_id: agent.id },
           headers: api_headers

      convo = Conversation.order(:created_at).last
      rid = convo.messages.where(role: "assistant").last.metadata["request_id"]

      expect(AgentStreamJob).to have_received(:perform_later).with(
        hash_including(request_id: rid, conversation_id: convo.id)
      )
    end

    it "renders the acknowledgment + thinking caption on the new conversation without running the job" do
      api_login(user)

      post conversations_path,
           params: { content: "hello", agent_id: agent.id },
           headers: api_headers

      convo = Conversation.order(:created_at).last

      get conversation_path(convo)
      expect(response.status).to eq(200)
      expect(response.body).to include("Your valuable input is received")
      expect(response.body).to include("Shams AI is thinking")
      expect(response.body).to include("data-thinking-ack")
      expect(response.body).to include("data-thinking-indicator")
    end
  end
end
# rubocop:enable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
