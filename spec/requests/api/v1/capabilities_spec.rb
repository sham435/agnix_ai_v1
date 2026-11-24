# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "API v1 capabilities", type: :request do
  let(:user) { create(:user) }

  it "requires authentication" do
    get "/api/v1/capabilities"
    expect(response).to have_http_status(401).or have_http_status(:redirect).or have_http_status(403)
  end

  it "lists capabilities with honest states for the frontend to render" do
    api_login(user)
    get "/api/v1/capabilities"

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)
    capabilities = data["capabilities"]

    expect(capabilities.pluck("key")).to include("chat", "attachments", "library", "file_extraction")
    expect(capabilities.pluck("key")).not_to be_empty

    chat = capabilities.find { |c| c["key"] == "chat" }
    expect(chat["state"]).to eq("enabled")
    expect(chat["input_schema"]).to include("type" => "object")
    expect(chat).to include("label", "description", "async", "execution_limits", "renderer")

    # Unconfigured providers report needs_authorization — never enabled.
    expect(capabilities.find { |c| c["key"] == "image_generation" }["state"]).to eq("needs_authorization")
    expect(capabilities.find { |c| c["key"] == "github" }["reason"]).to eq("requires_connection")
  end

  it "reports only the signed-in organization's search and Figma connections" do
    organization = create(:organization)
    create(:membership, user: user, organization: organization)
    %w[web_search figma].each do |provider|
      create(:tool_integration, organization: organization, provider: provider, credentials: { "api_key" => "test-key" })
    end
    api_login(user)
    get "/api/v1/capabilities"
    states = JSON.parse(response.body).fetch("capabilities").index_by { |cap| cap["key"] }
    expect(states.fetch("web_search")["state"]).to eq("enabled")
    expect(states.fetch("figma")["state"]).to eq("enabled")
    api_login(create(:user))
    get "/api/v1/capabilities"
    states = JSON.parse(response.body).fetch("capabilities").index_by { |cap| cap["key"] }
    expect(states.fetch("figma")["state"]).to eq("needs_authorization")
  end

  it "offers internal marketplace setup forms in the tools panel" do
    organization = create(:organization)
    create(:membership, user: user, organization: organization, role: "admin")
    api_login(user)
    get "/conversations"
    expect(response.body).to include('/integrations/connect/web_search', '/integrations/connect/figma')
    get "/integrations/connect/figma"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("file_content:read", "No writes.")
    get "/integrations/connect/web_search"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Tavily API key")
  end

  it "hides marketplace setup entry points from plain members (M15 H1)" do
    organization = create(:organization)
    create(:membership, user: user, organization: organization)
    api_login(user)
    get "/conversations"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('/integrations/connect/')
  end

  it "reports unavailability per configuration, not by guesswork" do
    blk = Capabilities::Registry.method(:web_search_configured?)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("k-allonsy")
    expect(blk.call).to be true
  end
end
