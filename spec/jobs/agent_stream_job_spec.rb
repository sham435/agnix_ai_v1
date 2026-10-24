# spec/jobs/agent_stream_job_spec.rb

# The event-contract examples intentionally assert several things per example
# (frame type + ordering + correlation ids) to prove the whole broadcast
# pipeline in one scenario.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe AgentStreamJob, type: :job do
  let(:user) { create(:user) }
  let(:conversation) { create(:conversation, user: user) }
  let(:user_message) { create(:message, conversation: conversation, role: "user", content: "Hi") }
  let(:runner) { instance_double(AgentRunner) }

  before do
    allow(AgentRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:run)
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(AgentAutoFixer).to receive(:new).and_return(instance_double(AgentAutoFixer, call: nil))

    stub_request(:post, %r{api\.openai\.com/v1/embeddings})
      .to_return(
        status: 200,
        body: { data: [ { embedding: [ 0.1 ] * 1536, index: 0 } ], usage: { prompt_tokens: 4, total_tokens: 4 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def perform_stream(message_id: nil)
    args = { conversation_id: conversation.id, user_id: user.id, message_content: "Hi" }
    args[:message_id] = message_id if message_id
    described_class.perform_now(**args)
  end

  # Captures the role of every message partial the job renders, in order.
  # Broadcasts go out synchronously right after each render, so this also
  # proves the arrival order of the Turbo Stream messages in the UI.
  def with_render_spy
    roles = []
    allow(ApplicationController).to receive(:render) do |**args|
      roles << args.dig(:locals, :message)&.role
      "html"
    end
    roles
  end

  # ── ordering: query above answer ────────────────────────────────────

  it "broadcasts the user query before the streaming reply bubble" do
    roles = with_render_spy
    perform_stream(message_id: user_message.id)

    expect(roles.take(2)).to eq(%w[user assistant])
  end

  it "renders only the reply bubble when no user message id is supplied" do
    roles = with_render_spy
    perform_stream

    expect(roles).to all(eq("assistant"))
  end

  # ── streaming indicator ─────────────────────────────────────────────

  it "creates the streaming placeholder with blank content and metadata.streaming" do
    # The root-cause fix: the job no longer persists a literal "." to satisfy
    # Message validation. Assistant rows in-flight carry an empty body plus a
    # metadata flag the view uses to render the animated thinking indicator.
    #
    # The stubbed AgentRunner in the outer `before` block does nothing, so
    # the placeholder row is left exactly as the job created it.
    perform_stream(message_id: user_message.id)

    placeholder = conversation.messages.reload.where(role: "assistant").order(:created_at).last
    expect(placeholder).to be_present
    expect(placeholder.content.to_s.strip).to eq("")
    expect(placeholder.metadata).to include("streaming" => true)
  end

  it "never persists a bare-dot assistant message during a streaming run" do
    # Regression guard for the historical bug where `content: "."` leaked
    # into the DB, LLM context window, and rendered bubble. Any dot-only
    # row is a bug.
    perform_stream(message_id: user_message.id)

    dot_rows = conversation.messages.where(role: "assistant").select do |m|
      [ ".", "..", "..." ].include?(m.content.to_s.strip)
    end
    expect(dot_rows).to be_empty
  end

  # ── completion ──────────────────────────────────────────────────────

  it "announces completion with the message + conversation correlation ids" do
    perform_stream(message_id: user_message.id)

    placeholder = conversation.messages.reload.where(role: "assistant").order(:created_at).last
    expect(ActionCable.server).to have_received(:broadcast).with(
      "conversation:#{conversation.id}",
      hash_including(type: "completed", message_id: placeholder.id, conversation_id: conversation.id)
    )
  end

  it "never announces the old bare 'complete' type" do
    perform_stream(message_id: user_message.id)

    types = broadcasted_types
    expect(types).not_to include("complete")
    expect(types).to include("completed")
  end

  # ── event contract: forwarded chunks carry correlation ids ──────────

  def broadcasted_payloads
    payloads = []
    allow(ActionCable.server).to receive(:broadcast) do |_stream, payload|
      payloads << payload
    end
    payloads
  end

  def broadcasted_types
    broadcasted_payloads.tap { perform_with_chunks } .map { |p| p[:type] }
  end

  def perform_with_chunks
    allow(runner).to receive(:run) do |_content, **_opts, &blk|
      blk&.call({ type: "status", phase: "connecting" })
      blk&.call({ type: "status", phase: "thinking" })
      blk&.call({ type: "content_delta", text: "Hel" })
      blk&.call({ type: "content_delta", text: "lo there" })
      blk&.call({ type: "status", phase: "generating" })
      blk&.call({ type: "tool_call", tool: "calculator", result: { ok: true } })
    end
    described_class.perform_now(conversation_id: conversation.id, user_id: user.id, message_content: "Hi")
  end

  it "forwards status + incremental content_delta + tool_call chunks to the browser" do
    payloads = broadcasted_payloads
    perform_with_chunks

    types = payloads.map { |p| p[:type] }
    expect(types).to include("status", "content_delta", "tool_call")

    # Genuine answer tokens are streamed as separate deltas — NOT collected
    # into one array and sent joined at the end.
    deltas = payloads.select { |p| p[:type] == "content_delta" }.map { |p| p[:text] }
    expect(deltas).to eq([ "Hel", "lo there" ])

    # Every forwarded frame is scoped to this conversation + placeholder so
    # concurrent conversations cannot cross-update.
    expect(payloads.all? { |p| p[:conversation_id] == conversation.id }).to be(true)
  end

  it "tags status events with the placeholder message id" do
    payloads = broadcasted_payloads
    perform_with_chunks

    status = payloads.find { |p| p[:type] == "status" && p[:phase] == "connecting" }
    expect(status).to be_present
    expect(status[:message_id]).to be_present
  end

  it "surfaces a provider failure as a 'failed' frame, not a fake completion" do
    allow(runner).to receive(:run) do |_content, **_opts, &blk|
      blk&.call({ type: "status", phase: "connecting" })
      raise Llm::OpenaiAdapter::LlmError, "provider down"
    end
    payloads = broadcasted_payloads

    described_class.perform_now(conversation_id: conversation.id, user_id: user.id, message_content: "Hi")

    types = payloads.map { |p| p[:type] }
    expect(types).to include("failed")
    expect(types).not_to include("completed")
    failed = payloads.find { |p| p[:type] == "failed" }
    expect(failed[:code]).to eq("provider_error")
    expect(failed[:conversation_id]).to eq(conversation.id)
  end

  # ── assistant_started bridge + request_id correlation (spec §2) ──────

  def perform_with_request_and_chunks(rid)
    payloads = broadcasted_payloads
    allow(runner).to receive(:run) do |_content, **_opts, &blk|
      blk&.call({ type: "status", phase: "connecting" })
      blk&.call({ type: "content_delta", text: "Hel" })
    end
    described_class.perform_now(
      conversation_id: conversation.id, user_id: user.id,
      message_content: "Hi", request_id: rid
    )
    payloads
  end

  it "broadcasts assistant_started before the first status frame" do
    payloads = perform_with_request_and_chunks("req-bridge-1")
    types = payloads.map { |p| p[:type] }

    started_index = types.index("assistant_started")
    status_index = types.index("status")
    expect(started_index).to be_present
    expect(status_index).to be_present
    expect(started_index).to be < status_index

    started = payloads[started_index]
    expect(started[:message_id]).to be_present
    expect(started[:request_id]).to eq("req-bridge-1")
    expect(started[:conversation_id]).to eq(conversation.id)
  end

  it "stamps the placeholder with request_id + stream_started_at and tags every frame" do
    payloads = perform_with_request_and_chunks("req-bridge-2")
    started = payloads.find { |p| p[:type] == "assistant_started" }

    placeholder = conversation.messages.reload.find(started[:message_id])
    expect(placeholder.metadata).to include("request_id" => "req-bridge-2")
    expect(placeholder.metadata["stream_started_at"]).to be_present

    # Every downstream frame carries the request_id so the browser can bridge
    # its optimistic container even when a frame arrives out of order.
    payloads.each do |p|
      next if p[:type] == "assistant_started" # also carries it, checked above

      expect(p[:request_id]).to eq("req-bridge-2")
    end
    expect(started[:request_id]).to eq("req-bridge-2")
  end

  it "reuses an in-flight placeholder instead of stacking a second one on retry" do
    # First run leaves a streaming placeholder (stubbed runner does nothing).
    described_class.perform_now(
      conversation_id: conversation.id, user_id: user.id,
      message_content: "Hi", request_id: "req-retry"
    )
    first_count = conversation.messages.where(role: "assistant").count

    # A retried enqueue with the SAME request_id must not create a second
    # live placeholder.
    described_class.perform_now(
      conversation_id: conversation.id, user_id: user.id,
      message_content: "Hi", request_id: "req-retry"
    )
    expect(conversation.messages.where(role: "assistant").count).to eq(first_count)
  end
end
