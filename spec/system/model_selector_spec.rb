require "rails_helper"

RSpec.describe "Dynamic chat model selector", :js, type: :system do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:agent) { create(:agent, organization: organization, tools: []) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    Rails.cache.clear
    create(:membership, :owner, user: user, organization: organization)
    create(:tool_integration, organization: organization, provider: "anthropic", credentials: { api_key: "selector-test-key" })
    stub_request(:get, "http://127.0.0.1:8080/v1/models").to_return(status: 200, body: { data: [ { id: "local" } ] }.to_json)
    stub_request(:get, "https://api.anthropic.com/v1/models").with(query: { limit: 100 })
      .to_return(status: 200, body: { data: [ { id: "catalogue-new-model", display_name: "New discovered model" } ] }.to_json)
    login_as user
    visit conversation_path(conversation)
    find('[data-action="model-selector#toggle"]').click
  end

  # rubocop:disable RSpec/MultipleExpectations
  it "groups discovered models by provider" do
    # Connection alone must never read as inference readiness (M14 Issue B).
    expect(page).to have_text("Anthropic · catalogue discovered - inference unverified")
    expect(page).not_to have_text("inference verified by a real request")
  end
  # rubocop:enable RSpec/MultipleExpectations

  it "searches model entries" do
    fill_in "Search models", with: "New discovered"
    expect(page).not_to have_selector("button", text: /bonsai-2-27b/)
  end

  it "persists the selected model across reload" do
    find("button", text: /New discovered model/).click
    find("button", text: "Model · New discovered model")
    visit conversation_path(conversation)
    expect(page).to have_button("Model · New discovered model")
  end

  it "refreshes externally added models" do
    stub_request(:get, "https://api.anthropic.com/v1/models").with(query: { limit: 100 })
      .to_return(status: 200, body: { data: [ { id: "second-model", display_name: "Second discovered model" } ] }.to_json)
    click_button "Refresh catalogue"
    expect(page).to have_selector("button", text: /Second discovered model/)
  end

  it "shows safe provider-discovery errors" do
    stub_request(:get, "https://api.anthropic.com/v1/models").with(query: { limit: 100 }).to_return(status: 401)
    click_button "Refresh catalogue"
    expect(page).to have_text("Anthropic: invalid_credentials")
  end

  it "leaves the agent unchanged when selecting another provider" do
    find("button", text: /bonsai-2-27b · Local/).click
    find("button", text: "Model · bonsai-2-27b")
    expect(agent.reload.provider).to eq("anthropic")
  end
end
