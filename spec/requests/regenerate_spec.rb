# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

# Regenerate wiring regression.
#
# The Regenerate affordance is a link. Under Turbo, `link_to ... method: :post`
# only emits the legacy `data-method` attribute, which Turbo Drive ignores — the
# click is dispatched as a GET. ConversationsController#regenerate deliberately
# treats a bare GET as a no-op guard (it must never destroy history or enqueue a
# run on a plain navigation/prefetch). So unless the link carries
# `data-turbo-method="post"`, clicking Regenerate silently does nothing and the
# thread appears stuck on the previous (still-streaming) "Shams AI is thinking…"
# bubble. These specs lock in both halves: the markup that makes the control a
# real POST, and the controller behaviour for GET vs POST.

require "rails_helper"

RSpec.describe "Conversation regenerate", type: :request do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    # api_login signs in through the forgery-skipped JSON session endpoint,
    # which populates the same session[:user_id] the HTML controllers read.
    api_login(user)

    conversation.messages.create!(role: "user", content: "extract text")
    conversation.messages.create!(role: "assistant", content: "the prior answer")

    # Never run the real provider from a request spec.
    allow(AgentStreamJob).to receive(:perform_later)
  end

  it "renders Regenerate as a Turbo POST link so the click is not a no-op GET" do
    get conversation_path(conversation)

    expect(response.body).to include('data-turbo-method="post"')
    # Both the header control and the per-message control post.
    regenerate_links = response.body.scan(%r{<a[^>]*href="[^"]*/regenerate"[^>]*>}).uniq
    expect(regenerate_links).not_to be_empty
    expect(regenerate_links).to all(include('data-turbo-method="post"'))
  end

  it "short-circuits a bare GET without touching history or the queue" do
    expect { get regenerate_conversation_path(conversation) }
      .not_to change { conversation.messages.count }

    expect(response).to redirect_to(conversation_path(conversation))
    expect(AgentStreamJob).not_to have_received(:perform_later)
  end

  it "destroys the last assistant reply and enqueues a fresh run on POST" do
    expect { post regenerate_conversation_path(conversation), headers: api_headers }
      .to change { conversation.reload.messages.where(role: "assistant").count }.by(-1)

    expect(response).to redirect_to(conversation_path(conversation))
    expect(AgentStreamJob).to have_received(:perform_later).with(
      conversation_id: conversation.id,
      user_id: user.id,
      message_content: "extract text"
    )
  end
end
