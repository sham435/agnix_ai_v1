# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ExpectInHook
require "rails_helper"

# Phase 1 — ChatGPT-style app shell: sidebar (collapse + persistence),
# two-theme system (toggle + persistence across navigation), the ⌘K search
# palette, and the composer send-control empty/enabled states.
RSpec.describe "Phase 1 app shell", :js, type: :system do
  let!(:user) { User.create!(email: "shell@example.com", password: "password123", name: "Shell User") }
  let!(:agent) do
    org = Organization.create!(name: "Shell Org", slug: "shell-org", owner: user)
    Membership.create!(user: user, organization: org, role: "owner")
    Agent.create!(name: "Shell Agent", slug: "shell-agent", system_prompt: "Hi.", organization: org, tools: [], is_active: true)
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Kubernetes migration notes") }

  # Poll an arbitrary JS/Ruby condition with Capybara's wait semantics.
  def wait_until(timeout = 5)
    Capybara.using_wait_time(timeout) do
      deadline = Time.now + timeout
      loop do
        result = yield
        return true if result
        break if Time.now > deadline
        sleep 0.1
      end
      !!yield
    end
  end

  def theme_attr
    page.evaluate_script("document.documentElement.getAttribute('data-theme')")
  end

  # Force a known device theme so assertions never depend on the headless
  # browser's prefers-color-scheme default.
  def seed_theme(theme)
    page.execute_script("localStorage.setItem('shams.theme', '#{theme}')")
    visit root_path
    expect(wait_until { theme_attr == theme }).to be(true)
  end

  def send_button
    find("#message-form button[type='submit']", visible: :all)
  end

  before do
    stub_request(:any, %r{api\.(anthropic|openai)\.com}).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    stub_request(:any, %r{localhost:11434}).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    login_as user
    # Clear device-scoped prefs and reload so each example begins from a clean,
    # deterministic baseline (expanded sidebar, OS-default theme).
    visit root_path
    page.execute_script("localStorage.removeItem('shams.theme'); localStorage.removeItem('shams.sidebar');")
    visit root_path
    Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, 1280, 900) if Capybara.page.driver.respond_to?(:resize_window_to)
    expect(page).to have_css("#sidebar", wait: 10)
  end

  it "renders the sidebar navigation, hiding not-yet-built phase slots" do
    within "#sidebar" do
      expect(page).to have_link("Chats")
      expect(page).to have_link("Agents")
      expect(page).to have_link("Memories")
      expect(page).to have_link("Integrations")
      expect(page).not_to have_link("Scheduled")
      expect(page).not_to have_link("Images")
      expect(page).not_to have_link("Explore")
    end
  end

  it "shows the conversation in the recency-grouped history list" do
    within "#sidebar" do
      expect(page).to have_text(/recent/i)
      expect(page).to have_link("Kubernetes migration notes", href: conversation_path(conversation))
    end
  end

  it "collapses to an icon-rail and persists that choice across navigation" do
    find("[data-sidebar-target='collapse']").click
    expect(page).to have_css("#sidebar[data-collapsed='true']", wait: 3)
    expect(page.evaluate_script("localStorage.getItem('shams.sidebar')")).to eq("rail")

    visit conversation_path(conversation)
    expect(page).to have_css("#sidebar[data-collapsed='true']", wait: 5)
    visit root_path
    expect(page).to have_css("#sidebar[data-collapsed='true']", wait: 5)
  end

  it "flips the theme and persists it after a full navigation" do
    seed_theme("dark")
    expect(theme_attr).to eq("dark")
    find("[data-theme-target='toggle']").click
    expect(wait_until { theme_attr == "light" }).to be(true)

    visit conversation_path(conversation)
    expect(wait_until { theme_attr == "light" }).to be(true)
    expect(page.evaluate_script("localStorage.getItem('shams.theme')")).to eq("light")
  end

  it "saves the chosen theme to the current user" do
    seed_theme("dark")
    find("[data-theme-target='toggle']").click
    uid = user.id
    expect(wait_until(6) { User.find(uid).ui_theme == "light" }).to be(true)
  end

  it "opens the ⌘K palette and returns the user's conversation from the endpoint" do
    page.execute_script("window.dispatchEvent(new CustomEvent('shams:search'))")
    expect(page).to have_css("[data-search-palette-target='modal']:not([hidden])", wait: 3)

    find("[data-search-palette-target='input']").set("kubernetes")
    within "[data-search-palette-target='results']" do
      expect(page).to have_link("Kubernetes migration notes", wait: 5)
    end

    find("body").send_keys(:escape)
    expect(page).to have_css("[data-search-palette-target='modal'][hidden]", visible: :all, wait: 3)
  end

  it "disables the composer send until there is text, then enables it" do
    visit conversation_path(conversation)
    expect(page).to have_field("message-input", wait: 10)
    expect(send_button).to be_disabled

    find("#message-input").set("Drafting a message")
    expect(wait_until { !send_button.disabled? }).to be(true)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/ExpectInHook
