# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# The provider-scoped Model select in a real browser.
#
# Both the agent form and the agent page used to render every provider's models
# in one flat list, so a person could pick provider=Google and leave a Claude id
# in the Model field. Nothing complained - the pair saved fine and only failed
# later as a 404 from the upstream API. These examples drive the two controls
# that replaced that list: the server-rendered scoped options (which must hold a
# saved model the catalog no longer offers, so opening a form and pressing Save
# cannot silently rewrite a working agent) and the provider-models Stimulus
# controller that rebuilds the Model select the moment the Provider changes.
RSpec.describe "Provider-scoped model select", :js, type: :system do
  let!(:user) { User.create!(email: "provider-scoped@example.com", password: "password123", name: "Scope") }
  let!(:org) do
    created = Organization.create!(name: "Scoped Org", slug: "scoped-org", owner: user)
    Membership.create!(user: user, organization: created, role: "owner")
    created
  end

  before do
    login_as user
  end

  # The selects carry no <label for>, so Capybara's label locator cannot reach
  # them; address them by the ids form_with generates.
  def model_options
    page.all("#agent_model option").map(&:value)
  end

  def provider_option_values
    page.all("#agent_provider option").map(&:value)
  end

  it "swaps the catalog when the provider changes, both directions" do
    visit new_agent_path
    # First matcher after navigation carries the wait: Cuprite can hand back the
    # document node before the DOM is attached.
    expect(page).to have_select("agent_provider", wait: 10)

    # The form's default provider is anthropic, so it starts on Claude ids only.
    expect(model_options).to eq(Agent::MODELS[:anthropic])
    expect(page).not_to have_select("agent_model", with_options: [ "gemini-3.5-flash" ])

    select "Google", from: "agent_provider"
    expect(page).to have_select("agent_model", with_options: Agent::MODELS[:google], wait: 10)
    expect(model_options).to eq(Agent::MODELS[:google])
    # Rebuilt from the catalog, so the previous provider's ids are gone and the
    # select lands on that provider's first model instead of nothing.
    expect(model_options).not_to include("claude-sonnet-4-6", "llama3.1")
    expect(page).to have_select("agent_model", selected: Agent::MODELS[:google].first)

    select "Anthropic", from: "agent_provider"
    expect(page).to have_select("agent_model", with_options: Agent::MODELS[:anthropic], wait: 10)
    expect(model_options).to eq(Agent::MODELS[:anthropic])
  end

  it "creates a Google agent on a Gemini model chosen from the rebuilt list" do
    visit new_agent_path
    expect(page).to have_field("agent_name", wait: 10)

    fill_in "agent_name", with: "Browser Gemini"
    select "Google", from: "agent_provider"
    expect(page).to have_select("agent_model", with_options: Agent::MODELS[:google], wait: 10)
    select "gemini-2.5-flash", from: "agent_model"
    click_button "Create Agent"

    expect(page).to have_content("Agent created successfully.", wait: 10)
    agent = org.agents.find_by(name: "Browser Gemini")
    expect(agent.provider).to eq("google")
    expect(agent.model).to eq("gemini-2.5-flash")
  end

  it "keeps a saved model outside the catalog until the provider is touched" do
    # ollama/local is a real tag on a local server but not in Agent::MODELS. The
    # scoped list must still show it (marked), so editing an unrelated field
    # cannot rewrite the agent's model.
    agent = create(:agent, organization: org, provider: "ollama", model: "local")
    visit edit_agent_path(agent)
    expect(page).to have_select("agent_provider", wait: 10)

    expect(model_options).to eq(Agent::MODELS[:ollama] + [ "local" ])
    expect(page).to have_select("agent_model", selected: "local (saved here)")

    click_button "Update Agent"
    expect(page).to have_content("Agent updated successfully.", wait: 10)
    expect(agent.reload.model).to eq("local")
    expect(agent.provider).to eq("ollama")
  end

  it "offers only this provider's models in the agent page switcher" do
    agent = create(:agent, organization: org, provider: "google", model: "gemini-2.5-flash")
    visit agent_path(agent)
    expect(page).to have_select("agent_model", wait: 10)

    # The page cannot change provider, so its auto-submitting switcher is pinned
    # to Gemini ids; a stray click can never send a Claude id.
    expect(model_options).to eq(Agent::MODELS[:google])
    expect(model_options).not_to include("claude-sonnet-4-6", "gpt-4o", "llama3.1")

    select "gemini-3.5-flash", from: "agent_model"
    # The select's own value is right immediately, so it proves nothing about the
    # change handler. Wait for the server round trip: this is what caught the
    # inline `onchange` never submitting under the app's CSP.
    expect(page).to have_content("Agent updated successfully.", wait: 10)
    expect(page).to have_select("agent_model", selected: "gemini-3.5-flash")
    expect(agent.reload.model).to eq("gemini-3.5-flash")
  end

  it "never lists a provider that has no models" do
    # Settings > Integrations builds its "model provider keys" rows from
    # Agent::MODELS.keys, and so does the Provider select - keeping the two in
    # step is what stopped google from being dead config again.
    visit new_agent_path
    expect(page).to have_select("agent_provider", wait: 10)
    expect(provider_option_values).to eq(Agent::MODELS.keys.map(&:to_s))
    expect(Agent.providers.values - provider_option_values).to be_empty
  end
end
