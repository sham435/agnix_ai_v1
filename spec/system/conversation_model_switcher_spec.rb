# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# The conversation header's model switcher in a real browser.
#
# That select sits in the chat header and patches the conversation's agent, then
# bounces back to the conversation. It was written as
# `onchange="this.form.requestSubmit()"`, which this app's CSP never executes:
# script-src carries a nonce, and a nonce voids 'unsafe-inline' for event handler
# attributes too, so picking a model looked like it worked (the select keeps the
# new value) while the agent stayed on the old one. Development hides it - CSP is
# report-only there - and request specs hide it too, because they never run JS.
# The examples below assert the round trip, not the select's own value.
RSpec.describe "Conversation model switcher saves", :js, type: :system do
  let!(:user) { User.create!(email: "conv-switcher@example.com", password: "password123", name: "Switch") }
  let!(:org) do
    created = Organization.create!(name: "Switcher Org", slug: "switcher-org", owner: user)
    Membership.create!(user: user, organization: created, role: "owner")
    created
  end
  let!(:agent) do
    create(:agent, organization: org, name: "Header Agent", slug: "header-agent",
                   provider: "anthropic", model: "claude-sonnet-4-6", tools: [])
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Switch Here") }

  before { login_as user }

  it "writes the new model to the agent and returns to the conversation" do
    visit conversation_path(conversation)
    # First matcher after navigation carries the wait: Cuprite can hand back the
    # document node before the DOM is attached.
    expect(page).to have_select("agent_model", wait: 10)

    select "claude-opus-4-8", from: "agent_model"
    expect(page).to have_content("Agent updated successfully.", wait: 10)
    expect(page).to have_current_path(conversation_path(conversation))
    expect(agent.reload.model).to eq("claude-opus-4-8")
    expect(page).to have_select("agent_model", selected: "claude-opus-4-8")
  end

  it "wires the change handler through Stimulus, not an inline attribute" do
    visit conversation_path(conversation)
    expect(page).to have_select("agent_model", wait: 10)

    switcher = page.find("#agent_model", visible: :all)
    expect(switcher["onchange"]).to be_nil
    expect(switcher["data-controller"]).to eq("auto-submit")
    expect(switcher["data-action"]).to eq("change->auto-submit#submit")
  end
end
