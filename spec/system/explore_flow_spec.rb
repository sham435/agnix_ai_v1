# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# Phase 5d — Explore in a real browser (Cuprite). Proves the catalog paints
# inside the app shell, the JS-free filters actually navigate, and "Start chat"
# is a genuine form POST carrying its own CSRF token: it materializes the
# template once per organization and lands the user in the new conversation.
RSpec.describe "Explore agents catalog", :js, type: :system do
  let!(:user) { User.create!(email: "explore@example.com", password: "password123", name: "Explorer") }
  let!(:org) do
    created = Organization.create!(name: "Explore Org", slug: "explore-org", owner: user)
    Membership.create!(user: user, organization: created, role: "owner")
    created
  end

  def card(slug)
    find("#agent-card-#{slug}")
  end

  it "lists every curated template with its launcher actions" do
    login_as user
    visit explore_path

    expect(page).to have_content("capabilities")
    expect(page).to have_css("[id^='agent-card-']", count: Agents::Templates.available.size)
    within(card("image-artist")) do
      expect(page).to have_button("Start chat")
      expect(page).to have_link("Customize", href: "/agents/new?template=image-artist")
      expect(page).not_to have_content("In your workspace")
    end
  end

  it "narrows the grid through the category chips" do
    login_as user
    visit explore_path

    # The chips are plain GET links, so every click replaces the whole
    # document. Capybara's default 2s window can expire before Cuprite has
    # re-resolved the new document node, and the query then raises
    # Capybara::Cuprite::ObsoleteNode (wrapping Ferrum::NodeNotFoundError)
    # instead of just reporting "not found yet". The explicit wait keeps the
    # retry loop alive across the full page load.
    click_on "Creative"
    expect(page).to have_css("#agent-card-image-artist", wait: 10)
    expect(page).not_to have_css("#agent-card-code-writer")
    expect(page).to have_field("q", wait: 10)

    click_on "All"
    # The path check reads from the driver (not the DOM), so it can succeed
    # before the new document is attached - the count matcher still needs its
    # own longer wait for the same reason as above.
    expect(page).to have_current_path(explore_path)
    expect(page).to have_css("[id^='agent-card-']",
                             count: Agents::Templates.available.size,
                             wait: 10)
  end

  it "searches the grid from the search field" do
    login_as user
    visit explore_path

    # Submitting the search form is a full navigation too (see the note in the
    # category-chips example), so the result matchers wait past the page load.
    fill_in "q", with: "translator"
    find("#q").send_keys :return
    expect(page).to have_css("#agent-card-arabic-english-translator", wait: 10)
    expect(page).not_to have_css("#agent-card-research-assistant")

    fill_in "q", with: "nothing-matches-this"
    find("#q").send_keys :return
    expect(page).to have_content("No template matches that search", wait: 10)
  end

  it "starts a chat from a template and reuses that agent afterwards" do
    login_as user
    visit explore_path

    within(card("research-assistant")) { click_button "Start chat" }

    conversation = Conversation.sole
    expect(page).to have_current_path(conversation_path(conversation))
    expect(conversation.title).to eq("New conversation with Research Assistant")
    expect(conversation.messages.count).to eq(0)
    expect(org.agents.where(slug: "research-assistant").count).to eq(1)

    visit explore_path
    expect(card("research-assistant")).to have_content("In your workspace")

    within(card("research-assistant")) { click_button "Start chat" }
    expect(Agent.count).to eq(1)
    expect(Conversation.count).to eq(2)
  end
end
