# spec/requests/explore_spec.rb

# Phase 5d — /explore HTTP contract: signed-in + organization-gated browsing,
# a strictly read-only GET (browsing must never materialize agents), JS-free
# filters, and the "Start chat" writer that funnels through
# Agents::InstantiateTemplate + Conversations::StartChat so the streaming
# placeholder contract is identical to a composer send. Unsafe requests need
# the CSRF header (this app verifies authenticity before controller
# callbacks), and AgentStreamJob is stubbed because tests run ActiveJob inline.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/NestedGroups

require "rails_helper"

RSpec.describe "Explore agents catalog", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization) }
  let(:slugs) { Agents::Templates.available.map { |template| template[:slug] } }

  before do
    create(:membership, user: user, organization: organization)
    allow(AgentStreamJob).to receive(:perform_later)
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def start_forms
    page.css("form").select { |form| form["action"].to_s.start_with?("/explore/start") }
  end

  def html_headers
    api_headers.merge("ACCEPT" => "text/html")
  end

  describe "access control" do
    it "sends anonymous visitors to the login wall" do
      get explore_path
      expect(response).to redirect_to(login_path)
    end

    it "sends organization-less users back to the root" do
      landless = create(:user)
      api_login(landless)

      get explore_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq("Please join or create an organization.")
    end
  end

  describe "GET /explore" do
    it "renders the catalog without writing anything" do
      api_login(user)

      expect { get explore_path }.not_to change(Agent, :count)
      expect(Conversation.count).to eq(0)
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("capabilities")
      expect(response.body).to include("Research Assistant")
      expect(response.body).to include("Arabic ⇄ English Translator")
      expect(response.body).to include("Image Artist")
      expect(start_forms.size).to eq(slugs.size)
      expect(page.css("a[href^='/agents/new?template=']").size).to eq(slugs.size)
      slugs.each do |slug|
        expect(response.body).to include(%(id="agent-card-#{slug}"))
      end
    end

    it "posts each card to the shared start endpoint and offers Customize" do
      api_login(user)
      get explore_path

      actions = start_forms.map { |form| [ form["method"], form["action"] ] }
      expect(actions).to all(include("post"))
      slugs.each do |slug|
        expect(actions.map(&:last)).to include(a_string_including("/explore/start?slug=#{slug}"))
      end
      expect(response.body).to include("/agents/new?template=code-writer")
      expect(response.body).to include("Start chat")
      expect(response.body).to include("Customize")
    end

    it "offers a chip per category and lights up the sidebar entry" do
      api_login(user)
      get explore_path

      Agents::Templates.categories.each do |category|
        expect(response.body).to include("category=#{category}")
      end
      expect(AppShell::Features.enabled?(:explore)).to be(true)

      nav_links = page.css("nav a[href='/explore']")
      expect(nav_links.size).to eq(1)
      expect(nav_links.first.text).to include("Explore")
      expect(nav_links.first["aria-current"]).to eq("page")
    end

    it "filters by search query, keeping only matching templates" do
      api_login(user)
      get explore_path(q: "translator")

      expect(response.body).to include("Arabic ⇄ English Translator")
      expect(response.body).not_to include(">Image Artist</h3>")
      expect(start_forms.size).to eq(1)
    end

    it "filters by category" do
      api_login(user)
      get explore_path(category: "Creative")

      expect(response.body).to include("Image Artist")
      expect(response.body).not_to include("Research Assistant")
      expect(start_forms.size).to eq(1)
    end

    it "explains an empty result set instead of rendering a blank grid" do
      api_login(user)
      get explore_path(q: "nothing-matches-this")

      expect(response.body).to include("No template matches that search")
      expect(start_forms).to be_empty
    end

    it "marks templates the organization already owns" do
      create(:agent, organization: organization, slug: "research-assistant", name: "Research Assistant")
      api_login(user)
      get explore_path

      expect(response.body).to include("In your workspace")
    end
  end

  describe "POST /explore/start" do
    it "instantiates the template and lands in a fresh conversation" do
      api_login(user)

      expect {
        post explore_start_path, params: { slug: "task-planner" }, headers: html_headers
      }.to change(Agent, :count).by(1).and change(Conversation, :count).by(1)

      agent = organization.agents.find_by(slug: "task-planner")
      conversation = Conversation.sole
      expect(agent).to be_present
      expect(agent.name).to eq("Task Planner")
      expect(conversation.agent).to eq(agent)
      expect(conversation.title).to eq("New conversation with Task Planner")
      expect(conversation.messages.count).to eq(0)
      expect(response).to redirect_to(conversation_path(conversation))
      expect(flash[:notice]).to eq("Task Planner is ready.")
    end

    it "reuses the organization's agent on a second start" do
      api_login(user)
      first = Agents::InstantiateTemplate.call(slug: "meeting-notes", organization: organization)

      expect {
        post explore_start_path, params: { slug: "meeting-notes" }, headers: html_headers
      }.not_to change(Agent, :count)

      expect(Conversation.sole.agent).to eq(first)
    end

    it "sends optional content through the composer startup contract" do
      api_login(user)
      payload = { slug: "email-drafter", content: "Chase the invoice politely" }
      post explore_start_path, params: payload, headers: html_headers

      conversation = Conversation.sole
      user_row = conversation.messages.find_by(role: "user")
      placeholder = conversation.messages.find_by(role: "assistant")

      expect(user_row.content).to eq("Chase the invoice politely")
      expect(conversation.title).to eq("Chase the invoice politely")
      expect(placeholder.content).to eq("")
      expect(placeholder.metadata["streaming"]).to be(true)
      expect(placeholder.metadata["request_id"]).to be_present
      expect(AgentStreamJob).to have_received(:perform_later).with(
        conversation_id: conversation.id,
        user_id: user.id,
        message_content: "Chase the invoice politely",
        request_id: placeholder.metadata["request_id"]
      )
    end

    it "answers 404 for unknown or missing slugs without creating agents" do
      api_login(user)

      post explore_start_path, params: { slug: "fictional-agent" }, headers: html_headers
      expect(response).to have_http_status(:not_found)

      post explore_start_path, params: {}, headers: html_headers
      expect(response).to have_http_status(:not_found)

      expect(Agent.count).to eq(0)
      expect(Conversation.count).to eq(0)
    end

    it "refuses starts without a CSRF token before touching the catalog" do
      post explore_start_path, params: { slug: "code-writer" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Agent.count).to eq(0)
    end

    it "creates the agent only inside the current organization" do
      other_org = create(:organization)
      other_user = create(:user)
      create(:membership, user: other_user, organization: other_org)
      api_login(user)

      post explore_start_path, params: { slug: "data-analyst" }, headers: html_headers

      expect(organization.agents.pluck(:slug)).to eq([ "data-analyst" ])
      expect(other_org.agents.count).to eq(0)
    end
  end

  describe "Customize prefill" do
    it "opens the agent form primed with the template's values" do
      api_login(user)
      get new_agent_path(template: "research-assistant")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="research-assistant"')
      expect(response.body).to include("rigorous research assistant")
      expect(response.body).to include("web_search")
    end

    it "leaves a blank form when the template is unknown" do
      api_login(user)
      get new_agent_path(template: "not-a-template")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("rigorous research assistant")
    end
  end
end
