# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe "Stalled run live recovery", :js, type: :system do
  let!(:user) { create(:user) }
  let!(:organization) { create(:organization, owner: user) }
  let!(:membership) { create(:membership, user: user, organization: organization, role: "owner") }
  let!(:agent) { create(:agent, organization: organization) }
  let!(:conversation) { create(:conversation, user: user, agent: agent) }

  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = previous
  end

  it "retires a silent thinking run into an honest 'didn't finish' state without a refresh" do
    login_as user
    visit conversation_path(conversation)
    expect(page).to have_css("#messages-container[data-controller='chat']", wait: 10)

    # Simulate an in-flight run whose server worker went silent: create the
    # optimistic assistant container (ack + thinking dots, no content) and a
    # matching turn whose activity clock is older than the stall threshold.
    injected = page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        if (!chat) return 'no-controller'
        const cid = 'stall-test-1'
        const node = document.createElement('div')
        node.setAttribute('data-assistant-pending', 'true')
        node.setAttribute('data-request-id', cid)
        node.setAttribute('data-message-role', 'assistant')
        node.setAttribute('data-streaming', 'true')
        node.innerHTML = '<div class="thinking-ack" data-thinking-ack>Your valuable input is received</div>' +
          '<span data-thinking-indicator class="thinking-indicator" role="status"><span class="thinking-dots">..</span></span>' +
          '<div data-streaming-content="pending-' + cid + '"></div>'
        document.getElementById('messages-list').appendChild(node)
        chat.turns.set(cid, { key: cid, rid: cid, mid: null, text: '', phase: 'thinking',
                              done: false, failed: false, lastActivity: Date.now() - 200000 })
        // Sanity: the spinner is live before the sweep.
        return document.querySelectorAll('[data-thinking-ack]').length
      })()
    JS
    expect(injected).to eq(1)

    # Fire the periodic stall sweep once (as it would run in the browser).
    page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        chat.sweepStalledTurns()
        return true
      })()
    JS

    # After: dots + acknowledgment are gone and an honest recovery hint shows.
    expect(page).to have_css("[data-stale-response-body]", text: "This response didn't finish", wait: 5)
    expect(page).not_to have_css("[data-thinking-ack]")
    expect(page).not_to have_css("[data-thinking-indicator]")
  end

  it "retires a server-rendered placeholder that never produced a cable turn (dashboard first message)" do
    # A placeholder the server stamped 110s ago: past the client stall threshold
    # (100s) but still inside the server's 2-minute stale window, so the page
    # renders it as a genuinely live "thinking" state. It predates the chat
    # controller connecting, so no cable-bridged turn was ever created for it —
    # only the DOM sweep can retire it.
    started = 110.seconds.ago.utc.iso8601
    create(:message, conversation: conversation, role: "user", content: "hi")
    create(
      :message,
      conversation: conversation,
      role: "assistant",
      content: "",
      tokens: nil,
      metadata: { "streaming" => true, "stream_started_at" => started, "request_id" => "stall-dom-1" }
    )

    login_as user
    visit conversation_path(conversation)
    expect(page).to have_css("#messages-container[data-controller='chat']", wait: 10)

    # Sanity: the placeholder rendered live and owns no in-memory turn.
    rendered = page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        const el = chat.element.querySelector('[data-message-role="assistant"][data-request-id="stall-dom-1"]')
        return JSON.stringify({
          streaming: el && el.getAttribute('data-streaming'),
          hasStamp: !!(el && el.getAttribute('data-stream-started-at')),
          turnExists: chat.turns.has('stall-dom-1'),
          acks: chat.element.querySelectorAll('[data-thinking-ack]').length
        })
      })()
    JS
    expect(JSON.parse(rendered)).to eq(
      "streaming" => "true", "hasStamp" => true, "turnExists" => false, "acks" => 1
    )

    # Fire the DOM sweep — the periodic interval runs the same pass.
    page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        chat.sweepStalledPlaceholders()
        return true
      })()
    JS

    expect(page).to have_css("[data-stale-response-body]", text: "This response didn't finish", wait: 5)
    expect(page).not_to have_css("[data-thinking-ack]")
    expect(page).not_to have_css("[data-thinking-indicator]")
    expect(page).to have_css("[data-request-id='stall-dom-1'][data-streaming='false']", wait: 2)
  end

  it "retires a slow-but-talking run whose stream started past the absolute ceiling (composer-guard parity)" do
    login_as user
    visit conversation_path(conversation)
    expect(page).to have_css("#messages-container[data-controller='chat']", wait: 10)

    # A reasoning model still streaming internal frames: lastActivity is
    # freshly refreshed every tick, so the SILENCE trigger (STALL_MS) would
    # never fire. The absolute ceiling (GENERATION_CEILING_MS = 130s) is the
    # safety net — measured from the server's stream_started_at, it retires
    # the run at the same instant the composer frees its Send guard.
    injected = page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        if (!chat) return 'no-controller'
        const cid = 'stall-ceiling-1'
        const started = new Date(Date.now() - 200000).toISOString() // 200s ago
        const node = document.createElement('div')
        node.setAttribute('data-assistant-pending', 'true')   // excluded from reconcile adopt
        node.setAttribute('data-request-id', cid)
        node.setAttribute('data-message-role', 'assistant')
        node.setAttribute('data-streaming', 'true')
        node.innerHTML = '<div class="thinking-ack" data-thinking-ack>Your valuable input is received</div>' +
          '<span data-thinking-indicator class="thinking-indicator" role="status"><span class="thinking-dots">..</span></span>' +
          '<div data-streaming-content="pending-' + cid + '"></div>'
        document.getElementById('messages-list').appendChild(node)
        // Fresh lastActivity (just now) — would survive the silence trigger.
        chat.turns.set(cid, { key: cid, rid: cid, mid: null, text: '', phase: 'generating',
                              done: false, failed: false,
                              lastActivity: Date.now(), startedAt: Date.now() - 200000,
                              streamStartedAt: started })
        // Sanity: not silent, but exceeded ceiling.
        return JSON.stringify({
          silentWouldFire: (Date.now() - chat.turns.get(cid).lastActivity) > chat.constructor.STALL_MS,
          elapsed: chat.turnElapsed(chat.turns.get(cid), Date.now()),
          ceiling: chat.constructor.GENERATION_CEILING_MS
        })
      })()
    JS
    sanity = JSON.parse(injected)
    expect(sanity["silentWouldFire"]).to be(false), "silence trigger should NOT fire (lastActivity is fresh)"
    expect(sanity["elapsed"]).to be > sanity["ceiling"]

    page.evaluate_script(<<~JS)
      (() => {
        const host = document.getElementById('messages-container')
        const chat = window.Stimulus.getControllerForElementAndIdentifier(host, 'chat')
        chat.sweepStalledTurns()
        return true
      })()
    JS

    expect(page).to have_css("[data-stale-response-body]", text: "This response didn't finish", wait: 5)
    expect(page).not_to have_css("[data-thinking-ack]")
    expect(page).not_to have_css("[data-thinking-indicator]")
  end
end
# rubocop:enable RSpec/LetSetup, RSpec/ExampleLength, RSpec/MultipleExpectations
