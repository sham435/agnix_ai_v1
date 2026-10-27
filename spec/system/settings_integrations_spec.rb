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
    # Readiness is asserted by each example's first matcher — Capybara polls,
    # and `expect` inside a hook trips RSpec/ExpectInHook.
    visit settings_integrations_path
  end

  it "saves a model provider key and lights the row up as active" do
    within "#provider-key-row-anthropic" do
      fill_in "Paste API key", with: "sk-ant-system-live-4321"
      click_button "Save key"
    end

    expect(page).to have_content("Anthropic key saved for Integration Org")
    within "#provider-key-row-anthropic" do
      expect(page).to have_content("Active")
      expect(page).to have_content("Organization key")
      # Only the fingerprint leaves the server, never the secret.
      expect(page).to have_content("4321")
      expect(page).not_to have_content("sk-ant-system-live-4321")
      expect(page).to have_button("Disable")
    end

    row = ToolIntegration.find_by(organization: org, provider: "anthropic")
    expect(row).to be_present
    expect(row.is_active?).to be(true)
    expect(row.decrypted_credentials["api_key"]).to eq("sk-ant-system-live-4321")
  end

  it "pauses and re-enables a stored provider key with the row toggle" do
    create(:tool_integration, organization: org, provider: "anthropic", name: "Anthropic API",
                              credentials: { "api_key" => "sk-ant-existing-1111" })
    visit settings_integrations_path

    within "#provider-key-row-anthropic" do
      expect(page).to have_content("Active")
      click_button "Disable"
    end
    expect(page).to have_content("Anthropic API disabled")
    within "#provider-key-row-anthropic" do
      expect(page).to have_content("Inactive")
      expect(page).to have_content("Organization key (paused)")
      click_button "Enable"
    end
    expect(page).to have_content("Anthropic API enabled")

    expect(ToolIntegration.find_by(organization: org, provider: "anthropic").reload.is_active?).to be(true)
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
