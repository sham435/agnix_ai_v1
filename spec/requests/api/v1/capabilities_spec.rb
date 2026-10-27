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

  it "reports unavailability per configuration, not by guesswork" do
    blk = Capabilities::Registry.method(:web_search_configured?)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("k-allonsy")
    expect(blk.call).to be true
  end
end
