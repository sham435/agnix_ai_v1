# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

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
#
# The behaviour half also pins the two live-app regressions: the old reply must
# survive a re-run (it used to be destroyed before enqueueing, so a failing run
# — or a second click — deleted answers), and one conversation may only have one
# live run (two concurrent AgentStreamJobs deadlocked on the agents row).

require "rails_helper"

RSpec.describe "Conversation regenerate", type: :request do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:enqueued) { [] }

  before do
    # api_login signs in through the forgery-skipped JSON session endpoint,
    # which populates the same session[:user_id] the HTML controllers read.
    api_login(user)

    conversation.messages.create!(role: "user", content: "extract text")
    conversation.messages.create!(role: "assistant", content: "the prior answer")

    # Never run the real provider from a request spec; capture the hand-off.
    allow(AgentStreamJob).to receive(:perform_later) { |**kwargs| enqueued << kwargs }
  end

  def assistant_rows
    conversation.reload.messages.where(role: "assistant").order(:created_at).to_a
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

  it "keeps the previous answer and claims the thread with a placeholder on POST" do
    prior = assistant_rows.last

    expect { post regenerate_conversation_path(conversation), headers: api_headers }
      .to change { assistant_rows.size }.by(1)

    expect(response).to redirect_to(conversation_path(conversation))
    expect(flash[:notice]).to eq(Conversations::RegenerateChat::QUEUED)

    # The old reply is still on disk: Regenerate no longer deletes it up front.
    expect(conversation.messages.find_by(id: prior.id)).to be_present
    expect(prior.reload.content).to eq("the prior answer")

    # The newest assistant row is the streaming placeholder the job will fill.
    placeholder = assistant_rows.last
    expect(placeholder.content.to_s.strip).to eq("")
    expect(placeholder).to be_streaming

    expect(enqueued.length).to eq(1)
    expect(enqueued.first).to include(
      conversation_id: conversation.id,
      user_id: user.id,
      message_content: "extract text",
      replaces_message_id: prior.id
    )
    # request_id ties the placeholder to the run, so the job reuses this exact
    # row instead of stacking a second placeholder (the StartChat contract).
    expect(enqueued.first[:request_id]).to eq(placeholder.metadata["request_id"])
    expect(enqueued.first[:request_id]).to be_present
  end

  it "regenerates from the newest user message, not a random one" do
    # `.last` on a uuid-keyed relation orders by the primary key, which for
    # these rows is effectively random: an older question used to be re-asked.
    conversation.messages.create!(role: "user", content: "first question", created_at: 2.days.ago)
    conversation.messages.create!(role: "assistant", content: "first answer")
    conversation.messages.create!(role: "user", content: "latest question")
    conversation.messages.create!(role: "assistant", content: "latest answer")

    post regenerate_conversation_path(conversation), headers: api_headers

    expect(enqueued.first[:message_content]).to eq("latest question")
    expect(enqueued.first[:replaces_message_id]).to eq(
      conversation.messages.where(role: "assistant", content: "latest answer").pick(:id)
    )
  end

  it "refuses a second click while a run is live instead of stacking another job" do
    post regenerate_conversation_path(conversation), headers: api_headers
    rows_after_first = assistant_rows.size

    expect { post regenerate_conversation_path(conversation), headers: api_headers }
      .not_to change { assistant_rows.size }

    expect(rows_after_first).to eq(2)
    expect(enqueued.length).to eq(1)
    expect(flash[:alert]).to eq(Conversations::RegenerateChat::BUSY)
    # Nothing was destroyed by the rejected click.
    expect(conversation.messages.where(role: "user").count).to eq(1)
  end

  it "treats a dead run's placeholder as no claim (a stale row cannot lock the thread)" do
    stale = conversation.messages.create!(
      role: "assistant", content: "",
      metadata: { "streaming" => true, "stream_started_at" => 10.minutes.ago.utc.iso8601 }
    )

    post regenerate_conversation_path(conversation), headers: api_headers

    expect(enqueued.length).to eq(1)
    expect(enqueued.first[:replaces_message_id]).to eq(stale.id)
    expect(flash[:notice]).to eq(Conversations::RegenerateChat::QUEUED)
  end

  it "says so when the thread has no answer to replace" do
    conversation.messages.where(role: "assistant").destroy_all

    expect { post regenerate_conversation_path(conversation), headers: api_headers }
      .not_to change { conversation.messages.count }

    expect(enqueued).to be_empty
    expect(flash[:alert]).to eq(Conversations::RegenerateChat::NOTHING_TO_REGENERATE)
  end
end
