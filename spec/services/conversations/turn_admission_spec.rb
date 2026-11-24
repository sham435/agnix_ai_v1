# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MessageSpies
RSpec.describe Conversations::TurnAdmission, type: :service do
  let(:user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before { allow(AgentStreamJob).to receive(:perform_later) }

  def start(content = "First turn", request_id = SecureRandom.uuid)
    described_class.call(conversation: conversation, user: user,
      params: { content: content, client_request_id: request_id })
  end

  def finish
    placeholder = conversation.messages.where(role: "assistant").order(:created_at).last
    placeholder.update!(content: "Finished response", metadata: placeholder.metadata.except("streaming"))
  end

  it "starts one turn with a user row, placeholder, and matching request id" do
    request_id = SecureRandom.uuid
    outcome = start("Hello", request_id)

    expect(outcome.status).to eq(:started)
    expect(conversation.messages.where(role: "user").count).to eq(1)
    expect(conversation.messages.where(role: "assistant").count).to eq(1)
    expect(conversation.messages.where(role: "assistant").last.metadata["request_id"]).to eq(request_id)
    expect(AgentStreamJob).to have_received(:perform_later).once.with(hash_including(request_id: request_id))
  end

  it "queues a follow-up without creating a user row or starting another run" do
    start
    outcome = described_class.call(conversation: conversation, user: user,
      params: { content: "Follow up", client_request_id: "follow-up" })

    expect(outcome.status).to eq(:queued)
    expect(outcome.queued_count).to eq(1)
    expect(conversation.messages.where(role: "user").count).to eq(1)
    expect(conversation.reload.metadata["m18_followups"].first).to include("content" => "Follow up")
    expect(AgentStreamJob).to have_received(:perform_later).once
  end

  it "stores steering without cancelling or replacing the live run" do
    initial = start
    outcome = described_class.call(conversation: conversation, user: user,
      params: { content: "Use the smaller patch", client_request_id: "steer-1" }, requested_mode: "steer")

    expect(outcome.status).to eq(:steering)
    expect(conversation.reload.metadata["m18_steering"].first).to include("content" => "Use the smaller patch")
    expect(described_class.task_summary(conversation)).to include(active: 1, active_request_id: initial.request_id)
    expect(AgentStreamJob).to have_received(:perform_later).once
  end

  it "delivers steering in order at the next safe boundary" do
    start
    %w[first second].each do |content|
      described_class.call(conversation: conversation, user: user,
        params: { content: content }, requested_mode: "steer")
    end

    expect(described_class.consume_steering(conversation)).to eq(%w[first second])
    expect(conversation.reload.metadata).not_to have_key("m18_steering")
    expect(conversation.messages.where(role: "user").count).to eq(1)
  end

  it "drains follow-ups FIFO, starting only after the previous placeholder finishes" do
    start
    %w[one two].each { |content| described_class.call(conversation: conversation, user: user, params: { content: content }) }

    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil
    finish
    first = described_class.dispatch_next(conversation: conversation, user: user)
    expect(first.message.content).to eq("one")
    expect(first.queued_count).to eq(1)
    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil

    finish
    second = described_class.dispatch_next(conversation: conversation, user: user)
    expect(second.message.content).to eq("two")
    expect(second.queued_count).to eq(0)
    expect(AgentStreamJob).to have_received(:perform_later).exactly(3).times
  end

  it "defers unused steering behind already queued follow-ups" do
    start
    described_class.call(conversation: conversation, user: user, params: { content: "queued" })
    described_class.call(conversation: conversation, user: user, params: { content: "steered" }, requested_mode: "steer")
    finish

    expect(described_class.dispatch_next(conversation: conversation, user: user).message.content).to eq("queued")
    finish
    expect(described_class.dispatch_next(conversation: conversation, user: user).message.content).to eq("steered")
  end

  it "keeps every accepted message when both waiting lists reach capacity" do
    start
    described_class::MAX_PENDING.times do |index|
      described_class.call(conversation: conversation, user: user, params: { content: "Follow-up #{index}" })
      described_class.call(conversation: conversation, user: user,
        params: { content: "Steering #{index}" }, requested_mode: "steer")
    end
    finish

    delivered = Array.new(described_class::MAX_PENDING * 2) do
      outcome = described_class.dispatch_next(conversation: conversation, user: user)
      expect(outcome).not_to be_nil
      finish
      outcome.message.content
    end

    expect(delivered).to eq(
      Array.new(described_class::MAX_PENDING) { |index| "Follow-up #{index}" } +
      Array.new(described_class::MAX_PENDING) { |index| "Steering #{index}" }
    )
    expect(described_class.task_summary(conversation)).to include(active: 0, queued: 0)
    expect(conversation.reload.metadata).not_to have_key("m18_steering")
  end

  it "accepts Action Cable string keys without losing content or request identity" do
    outcome = described_class.call(conversation: conversation, user: user,
      params: { "content" => "From the cable", "client_request_id" => "cable-request" })

    expect(outcome.status).to eq(:started)
    expect(outcome.message.content).to eq("From the cable")
    expect(outcome.request_id).to eq("cable-request")
    expect(conversation.messages.where(role: "user").last.metadata["client_request_id"]).to eq("cable-request")
  end

  it "keeps follow-ups queued while a real run remains active after the placeholder finishes" do
    start
    run = create(:run, :running, agent: agent, conversation: conversation)
    described_class.call(conversation: conversation, user: user, params: { content: "Wait for the run" })
    finish

    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil
    expect(described_class.task_summary(conversation)).to include(active: 1, queued: 1)
    expect(conversation.messages.where(role: "user").count).to eq(1)

    run.cancel!
    expect(described_class.dispatch_next(conversation: conversation, user: user).message.content).to eq("Wait for the run")
  end

  it "treats a manual plan awaiting approval as active and does not start a concurrent follow-up" do
    start
    finish
    plan = create(:agent_run, conversation: conversation, mode: "manual_plan", status: "planning")
    described_class.call(conversation: conversation, user: user, params: { content: "After approval" })

    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil
    summary = described_class.task_summary(conversation)
    expect(summary).to include(active: 1, queued: 1)
    expect(summary[:tasks].find { |task| task[:kind] == "plan" && task[:id] == plan.id }).to include(
      state: "waiting_for_user", actions: [ "stop", "approve_plan" ]
    )

    plan.update!(status: "completed")
    expect(described_class.dispatch_next(conversation: conversation, user: user).message.content).to eq("After approval")
  end

  it "retires a stopped placeholder from the active count while retaining queued messages" do
    start
    described_class.call(conversation: conversation, user: user, params: { content: "Still queued" })
    placeholder = conversation.messages.where(role: "assistant").order(:created_at).last
    placeholder.update!(metadata: placeholder.metadata.merge("stop_requested" => true))

    expect(described_class.task_summary(conversation)).to include(active: 0, queued: 1, active_request_id: nil)
    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil
    expect(conversation.reload.metadata["m18_followups"].size).to eq(1)
  end

  it "broadcasts an authoritative idle task snapshot when the queue is empty" do
    start
    finish

    expect(ActionCable.server).to receive(:broadcast).with(
      "conversation:#{conversation.id}",
      hash_including(type: "background_tasks", active: 0, queued: 0, tasks: [])
    )
    expect(described_class.dispatch_next(conversation: conversation, user: user)).to be_nil
  end

  it "deduplicates persisted and pending client request ids" do
    start("Original", "same-id")
    duplicate = start("Changed", "same-id")
    expect(duplicate.status).to eq(:duplicate)
    expect(duplicate.message.content).to eq("Original")

    queued = described_class.call(conversation: conversation, user: user,
      params: { content: "Pending", client_request_id: "pending-id" })
    pending_duplicate = described_class.call(conversation: conversation, user: user,
      params: { content: "Changed", client_request_id: "pending-id" })

    expect(queued.status).to eq(:queued)
    expect(pending_duplicate.status).to eq(:duplicate_pending)
    expect(conversation.reload.metadata["m18_followups"].size).to eq(1)
    expect(AgentStreamJob).to have_received(:perform_later).once
  end

  it "rejects a twenty-first follow-up without losing its content" do
    start
    described_class::MAX_PENDING.times do |index|
      described_class.call(conversation: conversation, user: user, params: { content: "Follow-up #{index}" })
    end
    outcome = described_class.call(conversation: conversation, user: user, params: { content: "Keep this draft" })

    expect(outcome.status).to eq(:invalid)
    expect(outcome.errors.first).to include("Too many waiting messages")
    expect(conversation.reload.metadata["m18_followups"].size).to eq(described_class::MAX_PENDING)
  end

  it "ignores unreadable assets and never attaches another user's file" do
    own = Asset.create!(user: user, filename: "own.txt", content_type: "text/plain", byte_size: 1,
      checksum: SecureRandom.hex(16), status: "ready", metadata: { "category" => "document" })
    foreign = Asset.create!(user: create(:user), filename: "foreign.txt", content_type: "text/plain", byte_size: 1,
      checksum: SecureRandom.hex(16), status: "ready", metadata: { "category" => "document" })
    outcome = described_class.call(conversation: conversation, user: user,
      params: { content: "Read these", attachment_asset_ids: [ own.id, foreign.id ] })

    expect(outcome.message.assets.reload.map(&:id)).to eq([ own.id ])
  end

  it "consumes an attachment draft only when its queued message actually starts" do
    asset = Asset.create!(user: user, filename: "draft.txt", content_type: "text/plain", byte_size: 1,
      checksum: SecureRandom.hex(16), status: "ready", metadata: { "category" => "document" })
    AttachmentDraft.record!(user: user, draft_token: "draft-token", asset: asset)
    start
    described_class.call(conversation: conversation, user: user,
      params: { attachment_asset_ids: [ asset.id ], attachment_draft_token: "draft-token" })

    expect(AttachmentDraft.where(user: user, draft_token: "draft-token", asset: asset)).to exist
    finish
    described_class.dispatch_next(conversation: conversation, user: user)
    expect(AttachmentDraft.where(user: user, draft_token: "draft-token", asset: asset)).not_to exist
  end

  it "rolls back a started turn when enqueueing fails" do
    allow(AgentStreamJob).to receive(:perform_later).and_raise(RuntimeError, "queue unavailable")

    expect { start }.to raise_error(RuntimeError, "queue unavailable")
    expect(conversation.messages.count).to eq(0)
    expect(conversation.reload.metadata).not_to have_key(described_class::QUEUE_KEY)
  end

  it "restores a queued follow-up when its dequeue enqueue fails" do
    start
    described_class.call(conversation: conversation, user: user,
      params: { content: "Retry me", client_request_id: "retry-enqueue" })
    finish
    allow(AgentStreamJob).to receive(:perform_later).and_raise(RuntimeError, "queue unavailable")

    expect { described_class.dispatch_next(conversation: conversation, user: user) }
      .to raise_error(RuntimeError, "queue unavailable")
    expect(conversation.messages.where(role: "user").count).to eq(1)
    expect(conversation.messages.where(role: "assistant").count).to eq(1)
    expect(conversation.reload.metadata[described_class::QUEUE_KEY].first).to include("content" => "Retry me")
  end

  it "keeps consumed steering request ids deduplicated after delivery" do
    start
    described_class.call(conversation: conversation, user: user,
      params: { content: "Use the smaller patch", client_request_id: "steer-retry" }, requested_mode: "steer")

    expect(described_class.consume_steering(conversation)).to eq([ "Use the smaller patch" ])
    retry_outcome = described_class.call(conversation: conversation, user: user,
      params: { content: "Use the smaller patch", client_request_id: "steer-retry" }, requested_mode: "steer")

    expect(retry_outcome.status).to eq(:duplicate)
    expect(conversation.reload.metadata[described_class::STEERING_IDS_KEY]).to include("steer-retry")
    expect(conversation.reload.metadata).not_to have_key(described_class::STEERING_KEY)
  end

  it "does not let placeholders with missing or malformed timestamps block admission" do
    conversation.messages.create!(role: "assistant", content: "", metadata: { "streaming" => true })
    conversation.messages.create!(role: "assistant", content: "", metadata: {
      "streaming" => true, "stream_started_at" => "not-a-time"
    })

    expect(described_class.live_placeholder(conversation)).to be_nil
    expect(described_class.task_summary(conversation)).to include(active: 0)
    expect(start.status).to eq(:started)
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MessageSpies
