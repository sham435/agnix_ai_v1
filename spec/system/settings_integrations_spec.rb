# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# Settings › Integrations in a real browser.
#
# The page used to be a read-only provider list with a status badge and zero
# controls, so every service looked stuck on "Inactive" with nothing to click.
# These examples drive the controls that replaced it: a model provider key form
# (the in-app way to swap an out-of-credit server key, because Agent#api_key
# prefers an active organization credential over ENV), the provider enable /
# disable toggle, and the marketplace card actions rendered from the shared
# partial — including the Turbo Stream card swap and the modal connect editor.
RSpec.describe "Settings integrations controls", :js, type: :system do
  let!(:user) { User.create!(email: "integrations@example.com", password: "password123", name: "Int") }
  let!(:org) do
    o = Organization.create!(name: "Integration Org", slug: "integration-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end

  before do
    login_as user
    stub_request(:get, %r{\Ahttps://api\.anthropic\.com/v1/models})
      .to_return(status: 200, body: { data: [ { id: "claude-test", display_name: "Claude Test" } ], has_more: false }.to_json)
    # Readiness is asserted by each example's first matcher — Capybara polls,
    # and `expect` inside a hook trips RSpec/ExpectInHook.
    visit settings_integrations_path
  end

  it "saves a model provider key and lights the row up as active" do
    within "#provider-row-anthropic" do
      fill_in "Paste API key", with: "sk-ant-system-live-4321"
      click_button "Save key"
    end

    expect(page).to have_content("Anthropic credentials saved; catalogue discovery succeeded.")
    within "#provider-row-anthropic" do
      # Discovery proves the credentials, not inference - the badge must say so.
      expect(page).to have_content("Catalogue available")
      expect(page).not_to have_content("Inference ready")
      expect(page).to have_content("Key configured (hidden)")
      # The secret never leaves the server, only the masked status renders.
      expect(page).not_to have_content("sk-ant-system-live-4321")
      expect(page).to have_button("Disable connection")
    end

    row = ToolIntegration.find_by(organization: org, provider: "anthropic")
    expect(row).to be_present
    expect(row.is_active?).to be(true)
    expect(row.decrypted_credentials["api_key"]).to eq("sk-ant-system-live-4321")
  end

  it "adds a manual model to a built-in provider without marking it verified" do
    groq = create(:tool_integration, organization: org, provider: "groq", name: "Groq API",
                                        credentials: { "api_key" => "test-only-system-groq-key" })
    stub_request(:get, "https://api.groq.com/openai/v1/models")
      .to_return(status: 200, body: { data: [] }.to_json)
    visit settings_integrations_path

    within "#provider-row-groq" do
      find("summary", text: "Add a model manually").click
      fill_in "Model ID", with: "groq-manual-system-model"
      fill_in "Display name", with: "Groq Manual System Model"
      select "Chat Completions", from: "API family"
      click_button "Save manual model"
    end

    expect(page).to have_content("Manual model metadata saved. No inference request was sent.")
    within "#provider-row-groq" do
      expect(page).to have_content("groq-manual-system-model")
      expect(page).to have_content("Inference unverified")
      expect(page).not_to have_content("Inference ready")
      expect(page).not_to have_content("test-only-system-groq-key")
    end
    expect(groq.reload.config.fetch("models").fetch("groq-manual-system-model")).to include(
      "api_family" => "chat_completions", "display_name" => "Groq Manual System Model"
    )
  end

  it "offers manual metadata editing for discovered built-in models" do
    create(:tool_integration, organization: org, provider: "groq", name: "Groq API",
                              credentials: { "api_key" => "test-only-system-groq-key" })
    stub_request(:get, "https://api.groq.com/openai/v1/models")
      .to_return(status: 200, body: { data: [ { id: "groq-discovered-system-model" } ] }.to_json)
    visit settings_integrations_path

    within "#provider-row-groq" do
      expect(page).to have_content("groq-discovered-system-model")
      expect(page).to have_css("summary", text: "Edit manual model metadata")
      expect(page).to have_content("Inference unverified")
    end
  end

  it "pauses and re-enables a stored provider connection with the row toggle" do
    create(:tool_integration, organization: org, provider: "anthropic", name: "Anthropic API",
                              credentials: { "api_key" => "sk-ant-existing-1111" })
    visit settings_integrations_path

    within "#provider-row-anthropic" do
      expect(page).to have_content("Catalogue available")
      click_button "Disable connection"
    end
    expect(page).to have_content("Anthropic connection disabled.")
    within "#provider-row-anthropic" do
      expect(page).to have_content("Disabled")
      click_button "Enable connection"
    end
    expect(page).to have_content("Anthropic connection enabled.")

    expect(ToolIntegration.find_by(organization: org, provider: "anthropic").reload.is_active?).to be(true)
  end

  it "marks an out-of-credit provider as billing blocked despite a live catalogue" do
    anthropic = create(:tool_integration, organization: org, provider: "anthropic", name: "Anthropic API",
                                          credentials: { "api_key" => "sk-ant-out-of-credit-0000" })
    anthropic.update_columns(config: anthropic.config.merge(
                               "last_inference_attempt_at" => Time.current.iso8601,
                               "last_inference_error_code" => "provider_credit_insufficient"))
    visit settings_integrations_path

    within "#provider-row-anthropic" do
      expect(page).to have_content("Billing blocked")
      expect(page).to have_content("Provider credits are insufficient")
      expect(page).not_to have_content("Inference ready")
    end
  end

  it "flips a plugin card between Connected and Paused in place over Turbo Stream" do
    slack = create(:tool_integration, organization: org, provider: "slack", name: "Team Slack")
    visit settings_integrations_path

    within "#plugin-card-slack" do
      expect(page).to have_content("Connected")
      click_button "Disable"
    end

    # Same DOM node replaced by the turbo_stream response — no full navigation.
    expect(slack.reload.is_active?).to be(false)
    within "#plugin-card-slack" do
      expect(page).to have_content("Paused")
      click_button "Enable"
    end
    expect(slack.reload.is_active?).to be(true)
    within "#plugin-card-slack" do
      expect(page).to have_content("Connected")
    end
  end

  it "opens the catalog credential editor through the shared modal frame" do
    within "#plugin-card-github" do
      click_link "Connect"
    end

    expect(page).to have_css("turbo-frame#modal", visible: :all, wait: 5)
    within "turbo-frame#modal" do
      expect(page).to have_content("Connect GitHub")
      expect(page).to have_field("tool_integration[credentials][api_key]", visible: :all)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
