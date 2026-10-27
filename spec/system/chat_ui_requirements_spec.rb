# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
require "rails_helper"

# §12: focused specs covering §1..§11 of the requirements brief.
#
# Each example maps to a specific numbered requirement so a reviewer can
# point at the failure and know which contract broke. Non-JS examples render
# the ERB directly (fast, deterministic). JS-dependent behaviour — the tools
# panel toggle, copy button, keyboard policy — runs against Cuprite with
# `js: true`.
RSpec.describe "Chat UI requirements bundle", :js, type: :system do
  let!(:user) do
    User.create!(email: "uireqs@example.com", password: "password123", name: "UI Reqs")
  end
  let!(:agent) do
    org = Organization.create!(name: "UI Reqs Org", slug: "ui-reqs-org", owner: user)
    Membership.create!(user: user, organization: org, role: "owner")
    Agent.create!(
      name: "Reqs Agent",
      slug: "reqs-agent",
      system_prompt: "You are helpful.",
      organization: org,
      tools: [],
      is_active: true
    )
  end
  let!(:conversation) do
    Conversation.create!(user: user, agent: agent, title: "Reqs Chat")
  end

  before do
    login_as user
    stub_request(:any, %r{api\.(anthropic|openai)\.com}).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    stub_request(:any, %r{localhost:11434}).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  # ── §1 / §2 — Rails 8.1 Live identity badge ──────────────────────────────
  describe "assistant identity badge" do
    let!(:message) do
      conversation.messages.create!(
        role: "assistant",
        content: "Hello there.",
        metadata: { "request_id" => "identity-1" }
      )
    end

    before { visit conversation_path(conversation) }

    it "renders the badge without hiding it on mobile (no hidden sm:flex)" do
      within "#assistant-message-#{message.id}" do
        badge = page.find("[role='status'][aria-label*='Rails 8.1 Live']")
        expect(badge[:class]).not_to match(/(^|\s)hidden(\s|$)/)
        expect(badge[:class]).not_to include("hidden sm:flex")
      end
    end

    it "keeps the pulse animation behind motion-safe so reduced-motion is honoured" do
      within "#assistant-message-#{message.id}" do
        dot = page.find("span[aria-hidden='true'].bg-emerald-500")
        expect(dot[:class]).to include("motion-safe:animate-pulse")
        expect(dot[:class]).not_to match(/(^|\s)animate-pulse(\s|$)/)
      end
    end

    it "still announces Shams AI via aria-label when the visible label collapses" do
      within "#assistant-message-#{message.id}" do
        badge = page.find("[role='status']")
        expect(badge["aria-label"]).to include("Rails 8.1 Live")
        expect(badge).to have_css("[class*='max-sm']")
      end
    end

    it "no longer renders the standalone 'S' avatar" do
      within "#assistant-message-#{message.id}" do
        # The previous identity marker was a link_to with a circle-rays SVG
        # wrapped around the letter "S". Neither the letter nor that wrapper
        # should remain.
        expect(page).not_to have_css("svg[viewBox='0 0 24 24'].lucide-circle-rays")
        text = page.find(".shrink-0").text
        expect(text.strip).not_to eq("S")
      end
    end
  end

  # ── §3 — homepage quick-start prompts and feature cards ──────────────────
  describe "homepage CTAs" do
    it "wires every quick-start chip to conversations_path with a prefilled prompt" do
      visit root_path
      chips = page.all("a", text: /Generate a Rails|Explain Solid|Create agent|Design a multi|Walk me through/)
      expect(chips.size).to be >= 3
      chips.first(3).each do |chip|
        expect(chip[:href]).to include("/conversations")
        expect(chip[:href]).to include("prompt=")
      end
    end

    it "renders three feature cards as real links, not dead divs" do
      visit root_path
      cards = page.all("a", text: /Better Coding|Smarter Agents|Rails 8.1 Native/)
      expect(cards.size).to eq(3)
      cards.each do |card|
        expect(card[:href]).to include("/conversations")
        expect(card[:href]).to include("prompt=")
      end
    end

    it "prefills the composer when arriving with ?prompt=..." do
      visit "#{root_path}?prompt=Generate%20a%20Rails%208.1%20controller"
      expect(page).to have_field("composer-input", with: /Rails 8\.1 controller/, wait: 5)
    end
  end

  # ── §4 / §5 — Tools panel + Integrations section ────────────────────────
  describe "Tools panel" do
    it "opens on click and closes on Escape" do
      visit root_path
      expect(page).to have_css("#dashboard-tools-panel[hidden]", visible: :all)
      find("button[aria-controls='dashboard-tools-panel']").click
      expect(page).to have_css("#dashboard-tools-panel:not([hidden])", wait: 3)
      find("body").send_keys(:escape)
      expect(page).to have_css("#dashboard-tools-panel[hidden]", visible: :all, wait: 3)
    end

    it "reflects truthful state for every advertised capability" do
      visit root_path
      find("button[aria-controls='dashboard-tools-panel']").click
      within "#dashboard-tools-panel" do
        expect(page).to have_content(/native tools/i)
        expect(page).to have_content(/integrations/i)
        expect(page).to have_content("Ready")
        %w[GitHub Notion Figma OpenAI].each do |name|
          expect(page).to have_content(name)
        end
      end
    end

    it "links each integration to its official service URL with safe attributes" do
      visit root_path
      find("button[aria-controls='dashboard-tools-panel']").click
      within "#dashboard-tools-panel" do
        expect(page).to have_link("GitHub site", href: "https://github.com/")
        expect(page).to have_link("Notion site", href: "https://www.notion.so/")
        expect(page).to have_link("Figma site",  href: "https://www.figma.com/")
        expect(page).to have_link("OpenAI site", href: "https://platform.openai.com/")
        all("a[target='_blank']").each do |ext|
          expect(ext["rel"]).to include("noopener")
        end
      end
    end
  end

  # ── §7 — footer claims match runtime configuration ───────────────────────
  describe "Powered-by footer" do
    it "renders the actual Rails version from Rails::VERSION" do
      visit root_path
      expect(page).to have_content("Built on Rails #{Rails::VERSION::STRING}")
      expect(page).to have_content("Solid Queue")
      expect(page).to have_content("Action Cable")
      expect(page).to have_content("Kamal 2")
    end
  end

  # ── §8 — copy button ─────────────────────────────────────────────────────
  describe "copy button" do
    let!(:message) do
      conversation.messages.create!(
        role: "assistant", content: "Copy me", metadata: {}
      )
    end

    it "carries an accessible label and is not a form-submit button" do
      visit conversation_path(conversation)
      within "#assistant-message-#{message.id}" do
        btn = page.find("button[data-action*='chat#copy']", visible: :all)
        expect(btn[:type]).to eq("button")
        expect(btn["aria-label"]).to eq("Copy response")
      end
    end

    it "restores the authored label once the copy feedback window closes" do
      # chat_controller.js once defined flashCopy twice; the later (shorter)
      # definition won and never stored the button's original aria-label, so the
      # restore step fell back to a generic "Copy" and clobbered "Copy response".
      visit conversation_path(conversation)
      within "#assistant-message-#{message.id}" do
        btn = page.find("button[data-action*='chat#copy']", visible: :all)
        btn.hover
        btn.click

        # Headless Chrome may grant or deny the clipboard write, so either
        # outcome is acceptable — but the label must come back to the authored one.
        expect(page).to have_css(
          "button[aria-label='Copied response'], button[aria-label='Copy failed']",
          visible: :all, wait: 3
        )
        expect(page).to have_css("button[aria-label='Copy response']", visible: :all, wait: 5)
      end
    end
  end

  # ── §9 — mode selector reliability ──────────────────────────────────────
  describe "mode toggle" do
    it "marks only the active mode with aria-pressed=true" do
      conversation.update!(mode: "manual_plan")
      visit conversation_path(conversation)
      within "#mode_toggle" do
        active = all("button[aria-pressed='true']").reject { |b| b[:title]&.include?("Interrupt") }
        expect(active.size).to eq(1)
        expect(active.first["data-mode"]).to eq("manual_plan")
        all("button[data-mode]").each do |btn|
          pressed = btn["aria-pressed"]
          expect(pressed == "true" || pressed == "false").to be(true),
            "expected aria-pressed to be 'true' or 'false', got #{pressed.inspect}"
        end
      end
    end

    it "keeps Chat as the default for a fresh conversation" do
      fresh = Conversation.create!(user: user, agent: agent, title: "Fresh")
      visit conversation_path(fresh)
      within "#mode_toggle" do
        expect(page).to have_css("button[data-mode=''][aria-pressed='true']")
      end
    end

    it "persists mode changes via PATCH" do
      visit conversation_path(conversation)
      within "#mode_toggle" do
        click_button("Auto Plan")
      end
      expect(page).to have_css("button[data-mode='auto_plan'][aria-pressed='true']", wait: 5)
      conversation.reload
      expect(conversation.mode).to eq("auto_plan")
    end
  end

  # ── §6 — keyboard submission policy ──────────────────────────────────────
  describe "keyboard submission policy" do
    def stub_platform(value)
      page.execute_script(<<~JS)
        (() => {
          const ctrl = window.Stimulus.controllers.find((c) => c.identifier === 'chat-input')
          if (!ctrl) throw new Error('chat-input controller not connected')
          const klass = ctrl.constructor
          if (!klass._origPlatformOf) klass._origPlatformOf = klass.platformOf.bind(klass)
          klass.platformOf = () => '#{value}'
          klass._platformCache = null
        })()
      JS
    end

    it "on desktop Enter submits" do
      visit conversation_path(conversation)
      stub_platform("desktop")
      fill_in "message-input", with: "hi desktop"
      find("#message-input").send_keys(:enter)
      expect(page).to have_field("message-input", with: "", wait: 5)
    end

    it "on macOS bare Enter inserts a newline and Cmd+Enter submits" do
      visit conversation_path(conversation)
      stub_platform("mac")
      fill_in "message-input", with: "hi mac"
      find("#message-input").send_keys(:enter)
      # Bare Enter must NOT submit on macOS — the draft stays visible with a
      # newline appended.
      expect(page).to have_field("message-input", with: "hi mac\n", wait: 3)
      find("#message-input").send_keys([ :meta, :enter ])
      expect(page).to have_field("message-input", with: "", wait: 5)
    end

    it "refuses to submit while an IME composition is active" do
      visit conversation_path(conversation)
      stub_platform("desktop")
      fill_in "message-input", with: "pre-ime"
      page.execute_script(<<~JS)
        (() => {
          const ta = document.getElementById('message-input')
          const ev = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
          Object.defineProperty(ev, 'isComposing', { value: true })
          ta.dispatchEvent(ev)
        })()
      JS
      # Draft untouched — no submit happened.
      expect(page).to have_field("message-input", with: /pre-ime/, wait: 2)
    end

    it "does not double-submit when Shift+Enter is pressed on desktop" do
      visit conversation_path(conversation)
      stub_platform("desktop")
      fill_in "message-input", with: "shift new line"
      find("#message-input").send_keys(%i[shift enter])
      # No submit — the composer keeps its draft with an appended newline.
      expect(page).to have_field("message-input", with: /shift new line\n/, wait: 2)
    end
  end

  # ── §11 — responsive overflow guardrails ────────────────────────────────
  describe "responsive layout" do
    [ [ 320, 640 ], [ 375, 667 ], [ 768, 1024 ], [ 1024, 768 ], [ 1440, 900 ] ].each do |w, h|
      it "keeps the homepage within #{w}x#{h} without horizontal scrolling" do
        visit root_path
        Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, w, h) if Capybara.page.driver.respond_to?(:resize_window_to)
        sleep 0.2
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        expect(overflow.to_i).to be <= 2
      end

      it "keeps the conversation page within #{w}x#{h} without horizontal scrolling" do
        conversation.messages.create!(role: "user", content: "hi")
        conversation.messages.create!(
          role: "assistant",
          content: "A sentence with a very long unbroken token like https://example.com/" + ("a" * 200)
        )
        visit conversation_path(conversation)
        Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, w, h) if Capybara.page.driver.respond_to?(:resize_window_to)
        sleep 0.2
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        expect(overflow.to_i).to be <= 2
      end
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
