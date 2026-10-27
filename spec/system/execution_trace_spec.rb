# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# Browser-side behaviour for the live, collapsible execution trace and the
# incremental streaming event contract. Rather than race a real provider, we
# drive the Stimulus chat controller's `handleStream` with the exact frames the
# server broadcasts, so the assertions are deterministic and cover the whole
# frontend contract:
#   * the trace starts collapsed and reveals an ordered step log on demand
#   * genuine answer tokens append incrementally (never buffered-and-replaced)
#   * the animated indicator stops once real content / completion / failure lands
#   * the model's private reasoning NEVER reaches the DOM
#   * events tagged for another conversation are ignored (no cross-updates)
RSpec.describe "Execution trace & streaming contract", :js, type: :system do
  let!(:user) { User.create!(email: "trace@example.com", password: "password123", name: "Trace") }
  let!(:org) do
    o = Organization.create!(name: "Trace Org", slug: "trace-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end
  let!(:agent) do
    Agent.create!(name: "Shams", slug: "shams-trace", system_prompt: "You are helpful.",
                  organization: org, provider: "anthropic", model: "claude-sonnet-4-6", tools: [])
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Trace") }
  let!(:placeholder) { conversation.messages.create!(role: "assistant", content: "", metadata: { "streaming" => true }) }

  before { login_as user }

  # Dispatch a single server frame through the live chat controller.
  def dispatch(frame)
    script = <<~JS
      (() => {
        const el = document.getElementById('messages-container');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'chat');
        if (!ctrl) return 'no-chat-controller';
        ctrl.handleStream(#{frame.to_json});
        return 'ok';
      })()
    JS
    result = page.evaluate_script(script)
    raise "chat controller unavailable: #{result}" if result == "no-chat-controller"
  end

  def body_text
    page.evaluate_script(<<~JS)
      document.querySelector('[data-streaming-content="#{placeholder.id}"]').textContent
    JS
  end

  def phase_text
    page.evaluate_script(<<~JS)
      document.querySelector('[data-message-id="#{placeholder.id}"] [data-execution-trace-target="phase"]').textContent
    JS
  end

  def log_hidden?
    page.evaluate_script(<<~JS)
      document.querySelector('[data-message-id="#{placeholder.id}"] [data-execution-trace-target="log"]').hidden
    JS
  end

  def log_text
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('[data-message-id="#{placeholder.id}"] .execution-trace__step')).map(li => li.textContent).join('|')
    JS
  end

  def indicator_present?
    page.evaluate_script(<<~JS)
      !!document.querySelector('[data-message-id="#{placeholder.id}"] [data-thinking-indicator]')
    JS
  end

  it "renders the trace collapsed with an animated indicator while streaming" do
    visit conversation_path(conversation)

    expect(page).to have_css("[data-execution-trace]", wait: 5)
    expect(page.evaluate_script(%(document.querySelector('[data-message-id="#{placeholder.id}"] [data-execution-trace-target="summary"]').getAttribute('aria-expanded')))).to eq("false")
    expect(log_hidden?).to be(true)
    expect(page).to have_css("[data-thinking-indicator][role='status']", count: 1)
  end

  it "expands to reveal the ordered step log on demand" do
    visit conversation_path(conversation)
    dispatch({ type: "status", phase: "connecting", message_id: placeholder.id, conversation_id: conversation.id })
    dispatch({ type: "status", phase: "thinking", message_id: placeholder.id, conversation_id: conversation.id })

    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector('[data-message-id="#{placeholder.id}"] [data-execution-trace]');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'execution-trace');
        ctrl.toggle();
      })()
    JS

    expect(log_hidden?).to be(false)
    expect(log_text).to include("Connecting")
    expect(log_text).to include("thinking")
    # Deduped: repeating the same phase must not stack identical steps.
    dispatch({ type: "status", phase: "thinking", message_id: placeholder.id, conversation_id: conversation.id })
    expect(log_text.scan("thinking").size).to eq(1)
  end

  it "streams genuine tokens incrementally and retires the indicator" do
    visit conversation_path(conversation)
    dispatch({ type: "status", phase: "connecting", message_id: placeholder.id, conversation_id: conversation.id })
    dispatch({ type: "content_delta", text: "Hello ", message_id: placeholder.id, conversation_id: conversation.id })

    expect(body_text).to eq("Hello ")
    expect(indicator_present?).to be(false)
    expect(phase_text).to include("Generating")

    dispatch({ type: "content_delta", text: "world", message_id: placeholder.id, conversation_id: conversation.id })
    # APPEND, not replace — the first delta must survive.
    expect(body_text).to eq("Hello world")
  end

  it "never renders the model's private reasoning into the DOM" do
    visit conversation_path(conversation)
    # A reasoning frame is not part of the browser contract and must be ignored.
    dispatch({ type: "reasoning", text: "PRIVATE_REASONING_MUST_NOT_LEAK", message_id: placeholder.id, conversation_id: conversation.id })
    # Only a throttled thinking status (no text) is ever forwarded.
    dispatch({ type: "status", phase: "thinking", message_id: placeholder.id, conversation_id: conversation.id })

    expect(page).not_to have_content("PRIVATE_REASONING_MUST_NOT_LEAK")
    expect(body_text.to_s).to eq("")
  end

  it "stops the indicator and marks failure on a provider error (no fake answer)" do
    visit conversation_path(conversation)
    dispatch({ type: "status", phase: "connecting", message_id: placeholder.id, conversation_id: conversation.id })

    dispatch({ type: "status", phase: "failed", error: "provider_unavailable", message_id: placeholder.id, conversation_id: conversation.id })

    expect(phase_text).to include("Failed")
    expect(indicator_present?).to be(false)
    expect(body_text.to_s).to eq("")
    expect(log_text).to include("Error")
  end

  it "marks completion on the finalized turn" do
    visit conversation_path(conversation)
    dispatch({ type: "status", phase: "generating", message_id: placeholder.id, conversation_id: conversation.id })
    dispatch({ type: "completed", message_id: placeholder.id, conversation_id: conversation.id })

    expect(phase_text).to include("Completed")
    expect(indicator_present?).to be(false)
  end

  it "ignores frames tagged for a different conversation" do
    visit conversation_path(conversation)
    other = Conversation.create!(user: user, agent: agent, title: "Other")

    dispatch({ type: "content_delta", text: "CROSS_TALK", message_id: placeholder.id, conversation_id: other.id })

    expect(body_text.to_s).to eq("")
    expect(page).not_to have_content("CROSS_TALK")
  end
end
