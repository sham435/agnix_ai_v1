# frozen_string_literal: true

require "rails_helper"

# Browser-side rendering pipeline: optimistic user bubbles, animated
# thinking indicator, empty-state handling, and responsive layout.
#
# Notes on the harness:
#   * Capybara + Cuprite provide a real Chrome via DevTools protocol.
#   * ActiveJob test env defaults to :inline so AgentStreamJob runs
#     synchronously during the HTTP request. Individual examples flip the
#     adapter to :test when we want the browser to observe the optimistic
#     state before the server has finished broadcasting the reconcile —
#     otherwise the reconcile lands in the same tick as the submit and
#     the assertion window vanishes.
RSpec.describe "Chat rendering & responsive UI", :js, :js, type: :system do
  let!(:user) do
    User.create!(email: "renderer@example.com", password: "password123", name: "Renderer")
  end

  let!(:org) do
    o = Organization.create!(name: "Renderer Org", slug: "renderer-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end

  let!(:agent) do
    Agent.create!(
      name: "Shams",
      slug: "shams-renderer",
      system_prompt: "You are helpful.",
      organization: org,
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      tools: []
    )
  end

  let!(:conversation) do
    Conversation.create!(user: user, agent: agent, title: "Rendering")
  end

  before do
    stub_request(:post, %r{api\.anthropic\.com/v1/messages})
      .to_return(
        status: 200,
        body: {
          id: "msg_rend",
          type: "message",
          role: "assistant",
          content: [ { type: "text", text: "Understood." } ],
          model: "claude-sonnet-4-6",
          stop_reason: "end_turn",
          usage: { input_tokens: 5, output_tokens: 3 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: { data: [ { embedding: [ 0.1 ] * 1536, index: 0 } ], usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    login_as user
  end

  # ── 1. Immediate user message (optimistic render) ─────────────────────
  describe "optimistic user bubble" do
    it "renders a matching optimistic bubble the moment the form is submitted" do
      # Freeze the streaming job so the reconcile broadcast is deferred and
      # we can inspect the DOM at the optimistic-only moment.
      queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      begin
        visit conversation_path(conversation)

        stub_composer_desktop!
        fill_in "message-input", with: "ping"
        find("#message-input").send_keys(:enter)

        expect(page).to have_css("[data-optimistic-user][data-client-request-id]", text: "ping", wait: 5)
        # The optimistic copy is the ONLY user bubble at this point because
        # the streaming job is not running.
        expect(page.all("[data-optimistic-user]", wait: false).size).to eq(1)
      ensure
        ActiveJob::Base.queue_adapter = queue_adapter
      end
    end

    it "keeps the draft AND drops the optimistic bubble on a validation failure" do
      # Force the controller into a 422 by stubbing Message#save to false
      # with an :content error. The optimistic bubble must disappear; the
      # composer keeps the typed text (the pre-existing draft-preservation
      # contract).
      allow(Message).to receive(:new).and_wrap_original do |orig, *args, **kwargs|
        inst = orig.call(*args, **kwargs)
        # Simulate validation failing after save attempt.
        def inst.save(*)
          errors.add(:content, "can't be blank")
          false
        end
        inst
      end

      visit conversation_path(conversation)
      stub_composer_desktop!
      fill_in "message-input", with: "will fail"
      find("#message-input").send_keys(:enter)

      # The optimistic bubble appears immediately on submit, then the
      # submit-end callback (failure branch) removes it.
      expect(page).to have_field("message-input", with: "will fail", wait: 5)
      expect(page).to have_no_css("[data-optimistic-user]", wait: 5)
    end
  end

  # ── 2. Thinking indicator lifecycle & dot animation ───────────────────
  describe "thinking indicator" do
    it "renders an animated indicator while the assistant placeholder is streaming" do
      streaming_msg = conversation.messages.create!(role: "user", content: "hi")
      # Attach an in-flight assistant placeholder the same way the job does.
      placeholder = conversation.messages.create!(
        role: "assistant", content: "", metadata: { "streaming" => true }
      )
      expect(streaming_msg).to be_present

      visit conversation_path(conversation)

      # The placeholder bubble exists, its streaming flag is on, and the
      # thinking indicator is present inside it.
      expect(page).to have_css(%([data-message-id="#{placeholder.id}"][data-streaming="true"]), wait: 5)
      expect(page).to have_css("[data-thinking-indicator][role='status']", count: 1, wait: 5)
      expect(page).to have_css(".sr-only", text: "Shams AI is thinking", wait: 2)
      # No stray "." visible inside the streaming body.
      within %(#assistant-message-#{placeholder.id}) do
        expect(page).to have_css("[data-streaming-content]", text: "", wait: 2)
      end
    end

    it "cycles the dot count via the Stimulus controller on ~400 ms ticks" do
      conversation.messages.create!(role: "user", content: "hi")
      placeholder = conversation.messages.create!(
        role: "assistant", content: "", metadata: { "streaming" => true }
      )

      visit conversation_path(conversation)
      expect(page).to have_css("[data-thinking-indicator]", wait: 5)

      # Observe transitions over a 1500 ms window — enough for at least
      # three ticks (400 → 800 → 1200). Capybara's `page.evaluate_script`
      # reads the DOM attribute directly, avoiding reliance on innerText
      # flicker.
      counts = []
      15.times do
        c = page.evaluate_script(
          "document.querySelector('#assistant-message-#{placeholder.id} [data-thinking-indicator]').dataset.dotCount"
        )
        counts << c.to_i
        sleep 0.1
      end

      # Across a 1.5s window the indicator should have cycled through at
      # least two distinct dot counts.
      expect(counts.uniq.size).to be >= 2
      expect(counts).to all(satisfy { |v| (0..3).cover?(v) })
    end

    it "does not persist a '.' as assistant content" do
      # Regression guard: nothing in the DOM or DB may present a bare-dot
      # assistant message to the user.
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(role: "assistant", content: "", metadata: { "streaming" => true })

      visit conversation_path(conversation)

      expect(page).to have_no_content(/^\.+$/)
      expect(conversation.messages.where(role: "assistant").map(&:content).join).not_to match(/\A\.+\z/)
    end
  end

  # ── 3. Empty response distinct state ─────────────────────────────────
  describe "empty response" do
    it "shows a dedicated 'no response' block when the provider returned nothing renderable" do
      conversation.messages.create!(role: "user", content: "hi")
      conversation.messages.create!(
        role: "assistant", content: "", metadata: { "empty_response" => true }
      )

      visit conversation_path(conversation)

      expect(page).to have_css("[data-empty-response='true']", wait: 5)
      expect(page).to have_css("[data-empty-response-body]", text: /no response/i, wait: 2)
      # Not the streaming indicator, not a fake apology.
      expect(page).to have_no_css("[data-thinking-indicator]")
      expect(page).to have_no_content("I'm sorry, I couldn't generate a response.")
    end
  end

  # ── 4. Responsive layout at typical breakpoints ──────────────────────
  describe "responsive layout" do
    # 320 / 375 / 768 / 1024 / 1440: no horizontal overflow anywhere in
    # the thread. This catches a bubble that escapes max-w-*, a pre/code
    # block wider than the viewport, or a table without wrapping.
    [ [ 320, 640 ], [ 375, 667 ], [ 768, 1024 ], [ 1024, 768 ], [ 1440, 900 ] ].each do |w, h|
      it "fits inside #{w}x#{h} without horizontal scrolling" do
        conversation.messages.create!(role: "user", content: "hi")
        conversation.messages.create!(
          role: "assistant",
          content: "A sentence with a very long unbroken token like https://example.com/" + ("a" * 200)
        )

        visit conversation_path(conversation)
        Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, w, h) if Capybara.page.driver.respond_to?(:resize_window_to)
        page.execute_script("document.documentElement.style.zoom = '1';") # defensive
        sleep 0.2

        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        expect(overflow).to be <= 1
      end
    end
  end

  # ── 5. Keyboard behaviour preserved ──────────────────────────────────
  describe "keyboard flow" do
    it "Enter submits, Shift+Enter inserts a newline" do
      visit conversation_path(conversation)
      stub_composer_desktop!

      fill_in "message-input", with: "one"
      find("#message-input").send_keys(%i[shift enter])
      expect(page).to have_field("message-input", with: "one\n", wait: 3)

      fill_in "message-input", with: "solo submit"
      find("#message-input").send_keys(:enter)
      # The optimistic bubble appears immediately; composer clears once the
      # server confirms the send.
      expect(page).to have_css("[data-optimistic-user][data-client-request-id]", text: "solo submit", wait: 3)
      expect(page).to have_field("message-input", with: "", wait: 5)
    end
  end
end
