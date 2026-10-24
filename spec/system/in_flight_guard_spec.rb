# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# In-flight guard + refresh-only thinking indicator fix (spec §1–§5).
#
# Two complementary strategies keep these deterministic:
#   * real form submit with a DEFERRED job adapter (:test) proves the live page
#     shows the assistant "thinking" container WITHOUT any server broadcast and
#     WITHOUT a page refresh — the headline defect.
#   * dispatching the exact Action Cable frames through the live chat controller
#     proves the bridge/buffer/reconcile/terminal contract without racing Chrome.
RSpec.describe "In-flight guard & live thinking indicator", :js, type: :system do
  let!(:user) { User.create!(email: "guard@example.com", password: "password123", name: "Guard") }
  let!(:org) do
    o = Organization.create!(name: "Guard Org", slug: "guard-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end
  let!(:agent) do
    Agent.create!(name: "Shams", slug: "shams-guard", system_prompt: "You are helpful.",
                  organization: org, provider: "anthropic", model: "claude-sonnet-4-6", tools: [])
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Guard") }

  # Defer the streaming job for the WHOLE example so the live page is driven
  # only by the browser-owned optimistic container plus the explicit Action
  # Cable frames we dispatch below. If we swapped the adapter back to :inline
  # the moment the optimistic bubble appeared, the still-in-flight POST could
  # enqueue (and run) the job inline, broadcasting the finalized reply and
  # racing the assertions — the indicator would vanish before we could count
  # it. `around` restores the original adapter so no other example is affected.
  around do |ex|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ex.run
  ensure
    ActiveJob::Base.queue_adapter = original
  end

  before do
    stub_request(:post, %r{api\.anthropic\.com/v1/messages})
      .to_return(status: 200, body: { content: [ { type: "text", text: "ok" } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(status: 200, body: { data: [ { embedding: [ 0.1 ] * 1536 } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    login_as user
  end

  # Drive the live chat controller with a single server frame.
  def dispatch(frame)
    result = page.evaluate_script(<<~JS)
      (() => {
        const el = document.getElementById('messages-container');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'chat');
        if (!ctrl) return 'no-chat-controller';
        ctrl.handleStream(#{frame.to_json});
        return 'ok';
      })()
    JS
    raise "chat controller unavailable: #{result}" if result == "no-chat-controller"
  end

  def js(script)
    page.evaluate_script("(#{script})")
  end

  # Submit while the job adapter is deferred (see the `before` hook) so the
  # optimistic assistant container is the ONLY thing on screen — exactly the
  # state the old code got wrong.
  def submit_deferred(text)
    visit conversation_path(conversation)
    stub_composer_desktop!
    fill_in "message-input", with: text
    find("#message-input").send_keys(:enter)
    expect(page).to have_css("[data-assistant-pending][data-request-id]", wait: 5)
  end

  def pending_request_id
    js("document.querySelector('[data-assistant-pending][data-request-id]').getAttribute('data-request-id')")
  end

  # §4: the placeholder appears without refreshing.
  it "shows the assistant thinking container the instant we send — no refresh, no server round-trip" do
    submit_deferred("extract text from wb.pdf")

    # Browser-owned container with a single live indicator, before any broadcast.
    expect(page).to have_css("[data-assistant-pending][data-request-id] [data-thinking-indicator][role='status']", count: 1, wait: 5)
    # Immediate acknowledgment line + the thinking caption (dots provide the
    # progressive ellipsis, so the label itself has no trailing "…").
    expect(page).to have_css("[data-assistant-pending] [data-thinking-ack]", text: "Your valuable input is received", count: 1, wait: 5)
    expect(page).to have_content("Shams AI is thinking")
    # The composer guard is engaged on the stable host.
    expect(page).to have_css("#messages-container[data-composer-busy]", wait: 2)
  end

  # §4: exactly one visual indicator, even after the server container lands.
  it "reconciles the real server container with the optimistic one — exactly one indicator" do
    submit_deferred("hi")
    rid = pending_request_id

    # Simulate the racy Turbo Stream append of the REAL assistant container.
    # The `js` helper wraps its argument in parentheses, so this must be a
    # self-invoking arrow function — a bare `() => {}` would only be defined,
    # never run.
    js(<<~JS)
      (() => {
        const list = document.getElementById('messages-list');
        const div = document.createElement('div');
        div.className = 'group/message';
        div.setAttribute('data-message-role', 'assistant');
        div.setAttribute('data-request-id', #{rid.to_json});
        div.setAttribute('data-message-id', 'real-mid-1');
        div.setAttribute('data-streaming', 'true');
        div.innerHTML = '<div class="thinking-ack" data-thinking-ack>Your valuable input is received</div>' +
          '<div data-execution-trace data-controller="execution-trace">' +
          '<button class="execution-trace__summary"><span data-thinking-indicator role="status" ' +
          'aria-live="polite"><span class="thinking-dots" aria-hidden="true"></span>' +
          '<span class="sr-only">Shams AI is thinking</span></span>' +
          '<span class="execution-trace__phase" data-execution-trace-target="phase">Shams AI is thinking</span>' +
          '</button></div><div data-streaming-content="real-mid-1"></div>';
        list.appendChild(div);
      })()
    JS

    # The optimistic duplicate is removed; only the real container survives.
    expect(page).to have_no_css("[data-assistant-pending][data-request-id='#{rid}']", wait: 5)
    expect(js("document.querySelectorAll('[data-request-id=#{rid.to_json}][data-message-role=assistant]').length")).to eq(1)
    expect(js("document.querySelectorAll('[data-thinking-indicator]').length")).to eq(1)
    # Exactly one acknowledgment line survives the reconcile (no duplicated ack).
    expect(js("document.querySelectorAll('[data-thinking-ack]').length")).to eq(1)
  end

  # §4: the first status/content event cannot be lost to a missing target, and
  # genuine content replaces the thinking indicator.
  it "bridges assistant_started to the real id and appends content into the optimistic container" do
    submit_deferred("extract from wb.pdf")
    rid = pending_request_id
    mid = "srv-#{rid[0, 8]}"

    dispatch({ type: "assistant_started", message_id: mid, request_id: rid, conversation_id: conversation.id })
    dispatch({ type: "status", phase: "thinking", message_id: mid, request_id: rid, conversation_id: conversation.id })
    # A content delta for a container the browser already owns renders immediately.
    dispatch({ type: "content_delta", text: "Extracted 66 pages.", message_id: mid, request_id: rid, conversation_id: conversation.id })

    body = js("document.querySelector('[data-request-id=#{rid.to_json}] [data-streaming-content]').textContent")
    expect(body).to eq("Extracted 66 pages.")
    # The container was bridged to the real message id.
    expect(js("document.querySelector('[data-request-id=#{rid.to_json}]').getAttribute('data-message-id')")).to eq(mid)
    # Indicator retired on the first genuine token.
    expect(js("document.querySelectorAll('[data-request-id=#{rid.to_json}] [data-thinking-indicator]').length")).to eq(0)
    # ...and so is the transient acknowledgment line — it is never part of the answer.
    expect(js("document.querySelectorAll('[data-request-id=#{rid.to_json}] [data-thinking-ack]').length")).to eq(0)
  end

  # §4: a completed frame terminates the live state and releases the guard.
  it "releases the in-flight guard on a matching completed frame" do
    submit_deferred("hi")
    rid = pending_request_id
    mid = "done-#{rid[0, 8]}"

    dispatch({ type: "assistant_started", message_id: mid, request_id: rid, conversation_id: conversation.id })
    dispatch({ type: "completed", message_id: mid, request_id: rid, conversation_id: conversation.id })

    # Host guard cleared → composer usable again.
    expect(js("document.getElementById('messages-container').dataset.composerBusy || ''")).to eq("")
    expect(js("document.querySelector('#message-form button[type=submit]').disabled")).to be(false)
    expect(js("document.querySelectorAll('[data-thinking-indicator]').length")).to eq(0)
    expect(js("document.querySelectorAll('[data-thinking-ack]').length")).to eq(0)
  end

  # §4: a provider failure stops the indicator and unlocks the composer.
  it "stops the indicator and releases the guard on a provider failure" do
    submit_deferred("hi")
    rid = pending_request_id
    mid = "fail-#{rid[0, 8]}"

    dispatch({ type: "assistant_started", message_id: mid, request_id: rid, conversation_id: conversation.id })
    dispatch({ type: "failed", message_id: mid, request_id: rid, message: "provider down", conversation_id: conversation.id })

    expect(js("document.querySelectorAll('[data-thinking-indicator]').length")).to eq(0)
    expect(js("document.querySelectorAll('[data-thinking-ack]').length")).to eq(0)
    expect(js("document.getElementById('messages-container').dataset.composerBusy || ''")).to eq("")
    expect(js("document.querySelector('#message-form button[type=submit]').disabled")).to be(false)
  end

  # §4: events belonging to another conversation are ignored.
  it "ignores frames tagged for a different conversation" do
    submit_deferred("hi")
    rid = pending_request_id
    other = Conversation.create!(user: user, agent: agent, title: "Other")

    dispatch({ type: "content_delta", text: "CROSS_TALK", message_id: "x", request_id: rid, conversation_id: other.id })

    body = js("document.querySelector('[data-request-id=#{rid.to_json}] [data-streaming-content]').textContent")
    expect(body.to_s).to eq("")
    expect(page).not_to have_content("CROSS_TALK")
  end

  # §4: a failed HTTP submission preserves the draft and re-enables retry.
  it "keeps the draft and unlocks the composer when the HTTP send is rejected" do
    # Force a 422 from the controller by failing Message#save.
    allow(Message).to receive(:new).and_wrap_original do |orig, *args, **kwargs|
      inst = orig.call(*args, **kwargs)
      def inst.save(*)
        errors.add(:content, "can't be blank")
        false
      end
      inst
    end

    visit conversation_path(conversation)
    stub_composer_desktop!
    fill_in "message-input", with: "this send will fail"
    find("#message-input").send_keys(:enter)

    # Draft preserved, optimistic assistant container retired, guard freed.
    expect(page).to have_field("message-input", with: "this send will fail", wait: 5)
    expect(page).to have_no_css("[data-assistant-pending]", wait: 5)
    expect(page).to have_no_css("[data-thinking-ack]", wait: 5)
    expect(js("document.getElementById('messages-container').dataset.composerBusy || ''")).to eq("")
    expect(js("document.querySelector('#message-form button[type=submit]').disabled")).to be(false)
  end

  # §4: a refresh restores the state of a genuinely active run from persisted data.
  it "renders the thinking indicator on refresh for a still-live stamped run" do
    conversation.messages.create!(role: "user", content: "hi")
    live = conversation.messages.create!(
      role: "assistant", content: "",
      metadata: { "streaming" => true, "request_id" => "live-run", "stream_started_at" => Time.current.utc.iso8601 }
    )

    visit conversation_path(conversation)

    expect(page).to have_css(%([data-message-id="#{live.id}"][data-streaming="true"][data-request-id="live-run"]), wait: 5)
    expect(page).to have_css("[data-thinking-indicator][role='status']", count: 1, wait: 5)
    # The acknowledgment line is restored too, straight from the persisted run.
    expect(page).to have_css("[data-thinking-ack]", text: "Your valuable input is received", count: 1, wait: 5)
  end

  # §4: a completed/stale run must NOT reappear as perpetually thinking.
  it "does not show perpetual thinking for a stale run after refresh" do
    conversation.messages.create!(role: "user", content: "hi")
    old = (Message::STREAMING_TIMEOUT + 10.seconds).ago.utc.iso8601
    dead = conversation.messages.create!(
      role: "assistant", content: "",
      metadata: { "streaming" => true, "request_id" => "dead-run", "stream_started_at" => old }
    )

    visit conversation_path(conversation)

    expect(page).to have_css(%([data-message-id="#{dead.id}"][data-streaming="false"]), wait: 5)
    expect(page).to have_css("[data-stale-response-body]", text: /didn't finish/i, wait: 2)
    expect(page).to have_no_css("[data-thinking-indicator]")
    expect(page).to have_no_css("[data-thinking-ack]")
    expect(page).not_to have_content("Shams AI is thinking")
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
