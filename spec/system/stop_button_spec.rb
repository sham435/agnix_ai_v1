# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# The header "Interrupt current run" button, driven by a real click.
#
# Pressing it used to be a visual no-op: the request answered a Turbo Stream
# form with `head :ok`, and it marked only plan runs — so during ordinary chat
# it stopped nothing and the tab never heard back. The page must now answer the
# press itself (indicator retired, composer freed, an acknowledgement in the
# thread) and flag the run the server-side job is watching.
RSpec.describe "Stop button", :js, type: :system do
  let!(:user) { User.create!(email: "stop@example.com", password: "password123", name: "Stop") }
  let!(:org) do
    o = Organization.create!(name: "Stop Org", slug: "stop-org", owner: user)
    Membership.create!(user: user, organization: o, role: "owner")
    o
  end
  let!(:agent) do
    Agent.create!(name: "Shams", slug: "shams-stop", system_prompt: "You are helpful.",
                  organization: org, provider: "anthropic", model: "claude-sonnet-4-6", tools: [])
  end
  let!(:conversation) { Conversation.create!(user: user, agent: agent, title: "Stop") }

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
    visit conversation_path(conversation)
    stub_composer_desktop!
  end

  def js(script)
    page.evaluate_script("(#{script})")
  end

  def dispatch(frame)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.getElementById('messages-container');
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'chat');
        ctrl.handleStream(#{frame.to_json});
      })()
    JS
  end

  # A turn the browser believes is generating, exactly as the live stream
  # leaves it before the first token: a thinking indicator, no content.
  def start_a_live_turn(placeholder, request_id)
    dispatch({ type: "assistant_started", message_id: placeholder.id,
               request_id: request_id, conversation_id: conversation.id })
    dispatch({ type: "status", phase: "thinking", message_id: placeholder.id,
               request_id: request_id, conversation_id: conversation.id })
    expect(page).to have_css("[data-thinking-indicator]", wait: 5)
  end

  def submit_and_send(text)
    fill_in "message-input", with: text
    find("#message-input").send_keys(:enter)
    expect(page).to have_css("[data-assistant-pending][data-request-id]", wait: 5)
    js("document.querySelector('[data-assistant-pending][data-request-id]').getAttribute('data-request-id')")
  end

  def stop_form_button
    find("form[action$='/stop'] button")
  end

  it "retires the live turn and flags the run the moment it is pressed" do
    run = Run.create!(agent: agent, conversation: conversation, status: "running",
      input: { "query" => "tell me a long story" })
    placeholder = conversation.messages.create!(role: "assistant", content: "",
      metadata: { "streaming" => true, "request_id" => "stop-req-1" })

    rid = submit_and_send("tell me a long story")
    start_a_live_turn(placeholder, rid)

    stop_form_button.click

    # No spinner left, and the trace names what happened rather than faking a
    # completion.
    expect(page).to have_no_css("[data-thinking-indicator]", wait: 5)
    expect(js("document.querySelector('[data-execution-trace] [data-execution-trace-target=phase]').textContent"))
      .to eq("Stopped")
    # The composer's generation guard is released by the same press.
    expect(page).to have_no_css("#messages-container[data-composer-busy]", wait: 5)
    # The tab is told, in the thread, that the press did something.
    expect(page).to have_content("Stopping the current run.", wait: 5)
    # And the run the job polls is flagged, which is what aborts the model.
    expect(run.reload.status).to eq("cancelled")
    expect(run.finished_at).to be_present
  end

  it "says so when there is nothing to stop" do
    submit_and_send("hello")

    stop_form_button.click

    expect(page).to have_content("Nothing is running in this conversation.", wait: 5)
    expect(page).not_to have_content("Stopping the current run.")
  end
end
