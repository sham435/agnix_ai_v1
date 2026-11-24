require "rails_helper"

RSpec.describe "Conversation model switcher saves", :js, type: :system do
  let(:user) { create(:user) }
  let(:org) { create(:organization, owner: user) }
  let(:agent) { create(:agent, organization: org, provider: "anthropic", model: "assigned-model", tools: []) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    Rails.cache.clear
    create(:membership, :owner, user: user, organization: org)
    create(:tool_integration, organization: org, provider: "anthropic", credentials: { api_key: "switcher-test-key" })
    stub_request(:get, "http://127.0.0.1:8080/v1/models").to_return(status: 200, body: { data: [] }.to_json)
    stub_request(:get, "https://api.anthropic.com/v1/models").with(query: { limit: 100 })
      .to_return(status: 200, body: { data: [ { id: "discovered-model", display_name: "Discovered model" } ] }.to_json)
    login_as user
    visit conversation_path(conversation)
  end

  it "writes the new model to the conversation, not the shared agent" do
    find('[data-action="model-selector#toggle"]').click
    find("button", text: "Discovered model · Cloud").click
    find("button", text: "Model · Discovered model")
    expect(conversation.reload.metadata.dig("selected_model", "model_id")).to eq("discovered-model")
  end

  it "wires selection through Stimulus rather than an inline handler" do
    switcher = find('[data-action="model-selector#toggle"]')
    expect(switcher["onclick"]).to be_nil
  end
end
