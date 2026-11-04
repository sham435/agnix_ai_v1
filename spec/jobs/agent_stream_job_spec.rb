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
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to)
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

  # ── progress on the row, for clients that only read the REST API ──────
  #
  # Action Cable carries the deltas to a live browser. The Flutter client has no
  # socket - it polls `GET /api/v1/conversations/:id`, which can only ever show
  # what is on the row. So the job writes the partial reply back to the
  # placeholder as it streams, and AgentRunner's final write replaces it in one
  # atomic update.
  describe "streamed progress on the placeholder row" do
    def placeholder
      conversation.messages.reload.where(role: "assistant").order(:created_at).last
    end

    def perform_with_deltas(texts)
      allow(runner).to receive(:run) do |_content, **_opts, &blk|
        texts.each { |text| blk&.call({ type: "content_delta", text: text }) }
      end
      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )
    end

    it "keeps the row in step with the deltas it broadcasts" do
      # Throttle disabled: every delta is written, so the row holds the answer
      # as far as the run has got - and is still flagged as being written.
      stub_const("AgentStreamJob::PROGRESS_WRITE_INTERVAL", 0.0)

      perform_with_deltas([ "Hel", "lo there" ])

      expect(placeholder.content).to eq("Hello there")
      expect(placeholder.streaming?).to be(true)
    end

    it "writes no more than once per interval" do
      # The default interval is 1s and these deltas arrive in one instant, so
      # only the first reaches the database. The rest are not lost: they are
      # broadcast immediately and the runner writes them with the final answer.
      perform_with_deltas([ "Hel", "lo there", " and more" ])

      expect(placeholder.content).to eq("Hel")
    end

    it "keeps the words a dead run wrote and names why it stopped" do
      stub_const("AgentStreamJob::PROGRESS_WRITE_INTERVAL", 0.0)
      allow(runner).to receive(:run) do |_content, **_opts, &blk|
        blk&.call({ type: "content_delta", text: "Half an answer" })
        raise "the model socket closed mid-stream"
      end

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      row = placeholder
      expect(row.streaming?).to be(false)
      # §4c: the partial is recovered verbatim, then followed by the same honest
      # tail AgentRunner's rescue writes - not a bare reply that breaks off
      # mid-sentence, and not a generic apology that buries the real words.
      expect(row.content).to eq("Half an answer#{AgentRunner::STOP_MARKER}")
      expect(row.metadata["error"]).to include("the model socket closed mid-stream")
      expect(row.metadata["error"]).to include("The reply stopped here.")
      expect(row.metadata["stopped_short"]).to be(true)
      # An empty-body recovery marker would be a lie here: there are words.
      expect(row.metadata).not_to have_key("empty_response")
    end

    # The two error paths must agree and never compound. When AgentRunner's
    # rescue (§4b) already finalized the placeholder - it wrote the partial with
    # the marker and cleared the streaming flag - the job's failure finalize is
    # a no-op: a row that is no longer "live" is left exactly as the runner set
    # it, so the honest tail is never appended twice.
    it "leaves a placeholder AgentRunner already finalized untouched (§4c idempotent)" do
      stub_const("AgentStreamJob::PROGRESS_WRITE_INTERVAL", 0.0)
      allow(runner).to receive(:run) do |_content, **_opts|
        # Emulate §4b: the runner rescued the provider error itself, wrote the
        # partial plus the shared marker and dropped the streaming flag...
        row = conversation.messages.reload.where(role: "assistant").order(:created_at).last
        row.update!(
          content: "Half an answer#{AgentRunner::STOP_MARKER}",
          metadata: { "error" => "provider reset", "stopped_short" => true }
        )
        # ...then re-raised so this job's rescue path also reaches its finalize.
        raise "provider reset"
      end

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      row = placeholder
      # Exactly one marker - the finalize saw streaming was already gone and
      # returned early rather than re-writing the row.
      expect(row.content.scan(AgentRunner::STOP_MARKER).length).to eq(1)
      expect(row.metadata["stopped_short"]).to be(true)
      expect(row.metadata["error"]).to eq("provider reset")
    end
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

  # ── stalled / failed run live-recovery (spec: no perpetual thinking) ──

  it "clears the placeholder's live flag on failure so recovery is immediate (not deferred to the stale window)" do
    # A provider error raised straight out of the run (bypassing the runner's
    # internal finalize) must not leave the row "streaming" — otherwise a
    # refresh keeps showing the thinking indicator until the 2-minute stale
    # window elapses. The job's rescue now finalizes it in one write.
    allow(runner).to receive(:run).and_raise(Llm::OpenaiAdapter::LlmError, "provider down")

    described_class.perform_now(
      conversation_id: conversation.id, user_id: user.id,
      message_content: "Hi", request_id: "req-fail"
    )

    placeholder = conversation.messages.reload.where(role: "assistant").order(:created_at).last
    expect(placeholder.streaming?).to be(false)
    expect(placeholder.metadata).to include("empty_response" => true)
    expect(placeholder.metadata).not_to include("streaming")
  end

  it "still emits a terminal frame and finalizes the row when no StandardError handler runs" do
    # A non-StandardError (or an error escaping the rescue) is caught by the
    # `ensure` safety net: the browser gets a terminal `failed` frame and the
    # placeholder stops being live, so the UI never spins forever.
    allow(runner).to receive(:run).and_raise(Exception, "wedged worker")
    payloads = broadcasted_payloads

    expect do
      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id,
        message_content: "Hi", request_id: "req-ensure"
      )
    end.to raise_error(Exception, "wedged worker")

    expect(payloads.map { |p| p[:type] }).to include("failed")
    placeholder = conversation.messages.reload.where(role: "assistant").order(:created_at).last
    expect(placeholder.streaming?).to be(false)
  end

  # ── superseded reply (Conversations::RegenerateChat contract) ─────────
  #
  # Regenerate no longer destroys the previous answer before enqueueing: it
  # hands the row to the job and only a genuine replacement may retire it. These
  # examples are the whole reason a failed re-run keeps the user's answer.
  describe "replaces_message_id" do
    let(:superseded) { conversation.messages.create!(role: "assistant", content: "the answer to keep") }

    # Write a finalized reply into the placeholder the way AgentRunner does.
    def stub_finalized_run(content, metadata_extra = {})
      allow(runner).to receive(:run) do |_content, **_opts|
        row = conversation.messages.reload.where(role: "assistant").order(:created_at).last
        row.update!(content: content, tokens: 3, metadata: row.metadata.merge(metadata_extra).except("streaming"))
      end
    end

    def perform_replacing
      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id,
        message_content: "Hi", replaces_message_id: superseded.id
      )
    end

    it "retires the superseded reply once a real answer lands" do
      stub_finalized_run("the new answer")
      superseded # the row about to be replaced must exist before the run starts
      before = conversation.messages.where(role: "assistant").count

      perform_replacing

      # one placeholder in, the superseded row out: the thread keeps its size
      expect(conversation.messages.where(role: "assistant").count).to eq(before)
      expect(conversation.messages.reload.find_by(id: superseded.id)).to be_nil
      expect(Turbo::StreamsChannel).to have_received(:broadcast_remove_to).with(
        conversation, target: "assistant-message-#{superseded.id}"
      )
      kept = conversation.messages.reload.where(role: "assistant").order(:created_at).last
      expect(kept.content).to eq("the new answer")
    end

    it "keeps the previous answer when the re-run raises" do
      allow(runner).to receive(:run).and_raise(Llm::OpenaiAdapter::LlmError, "provider down")

      perform_replacing

      expect(conversation.messages.reload.find_by(id: superseded.id)&.content)
        .to eq("the answer to keep")
    end

    it "keeps the previous answer when the re-run finalizes with an error marker" do
      stub_finalized_run("I encountered an error while processing your request.", "error" => "boom")

      perform_replacing

      expect(conversation.messages.reload.find_by(id: superseded.id)&.content)
        .to eq("the answer to keep")
    end

    it "keeps the previous answer when the re-run produces an empty body" do
      # AgentRunner's own contract: a blank finalization carries
      # metadata["empty_response"], never a fabricated dot.
      stub_finalized_run("", "empty_response" => true)

      perform_replacing

      expect(conversation.messages.reload.find_by(id: superseded.id)&.content)
        .to eq("the answer to keep")
    end
  end

  # ── honest terminal frames ────────────────────────────────────────────
  #
  # AgentRunner rescues provider errors, writes an honest error state into the
  # placeholder and returns the bad news in its result hash instead of raising.
  # The job used to ignore that verdict and announce `completed` anyway — the
  # browser stopped "thinking" on a lie, and a failed re-run retired the answer
  # it was supposed to replace.
  describe "run failure verdict" do
    def stub_reported_failure(message = "provider down")
      allow(runner).to receive(:run) do |_content, **_opts, &blk|
        blk&.call({ type: "status", phase: "failed", error: message })
        row = conversation.messages.reload.where(role: "assistant").order(:created_at).last
        row.update!(
          content: "I encountered an error while processing your request.",
          metadata: row.metadata.merge("error" => message).except("streaming")
        )
        { content: "I encountered an error while processing your request.", error: message }
      end
    end

    it "announces failed with the provider's reason instead of completed" do
      stub_reported_failure
      payloads = broadcasted_payloads

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      types = payloads.map { |p| p[:type] }
      expect(types).not_to include("completed")
      failed = payloads.find { |p| p[:type] == "failed" }
      expect(failed[:code]).to eq("provider_error")
      expect(failed[:message]).to eq("provider down")
      expect(failed[:message_id]).to be_present
      expect(failed[:conversation_id]).to eq(conversation.id)
    end

    it "keeps the superseded reply when the re-run only reports failure" do
      superseded = conversation.messages.create!(role: "assistant", content: "the answer to keep")
      stub_reported_failure

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id,
        message_content: "Hi", replaces_message_id: superseded.id
      )

      expect(conversation.messages.reload.find_by(id: superseded.id)&.content)
        .to eq("the answer to keep")
      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_remove_to)
    end
  end

  # ── run budget (the Timeout.timeout replacement) ──────────────────────
  #
  # The job used to wrap the run in `Timeout.timeout(RUN_TIMEOUT_SECONDS)`. The
  # raise landed at an arbitrary instruction — including inside the DB write that
  # persists the reply — rolled the placeholder back, and reached the user as the
  # meaningless "Agent error: execution expired". The budget is now a checkpoint
  # between chunks: it can only fire where nothing is mid-flight, and it says
  # which limit it hit.
  describe "run budget" do
    # Comments may name the removed construct to explain why; code may not use it.
    def job_code
      File.read(Rails.root.join("app/jobs/agent_stream_job.rb"))
           .lines.reject { |line| line.lstrip.start_with?("#") }
           .join
    end

    def captured_turbo_html
      fragments = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) do |_target, **kwargs|
        fragments << kwargs[:html].to_s
      end
      fragments
    end

    it "no longer interrupts runs with Timeout" do
      code = job_code
      expect(code).not_to include("Timeout.timeout")
      expect(code).not_to include("RUN_TIMEOUT_SECONDS")
      expect(code).not_to match(/^require "timeout"/)
    end

    it "stops an endless run at a chunk boundary with an honest reason" do
      allow(runner).to receive(:run) do |_content, **_opts, &blk|
        blk&.call({ type: "content_delta", text: "Hel" })
        blk&.call({ type: "content_delta", text: "lo" })
      end
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(described_class).to receive(:elapsed_seconds)
        .and_return(AgentStreamJob::RUN_LIMIT + 1)
      # rubocop:enable RSpec/AnyInstance
      payloads = broadcasted_payloads
      html = captured_turbo_html

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id,
        message_content: "Hi", request_id: "req-budget"
      )

      types = payloads.map { |p| p[:type] }
      expect(types).to include("failed")
      expect(types).not_to include("completed")
      expect(payloads.find { |p| p[:type] == "failed" }[:code]).to eq("run_timeout")

      # The in-chat error says what happened instead of "execution expired".
      expect(html.join).to include("without reaching an answer")
      expect(html.join).not_to include("execution expired")

      # Because the stop happens between chunks, the placeholder still exists
      # and gets finalized: nothing is rolled back and nothing spins forever.
      started = payloads.find { |p| p[:type] == "assistant_started" }
      placeholder = conversation.messages.reload.find(started[:message_id])
      expect(placeholder.streaming?).to be(false)
    end

    it "lets a slow but progressing run finish (a stalled local model is not a wedged one)" do
      allow(runner).to receive(:run) do |_content, **_opts, &blk|
        blk&.call({ type: "content_delta", text: "Hel" })
        row = conversation.messages.reload.where(role: "assistant").order(:created_at).last
        row.update!(content: "Hello there", tokens: 4, metadata: row.metadata.except("streaming"))
      end
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(described_class).to receive(:elapsed_seconds)
        .and_return(20 * 60)
      # rubocop:enable RSpec/AnyInstance
      payloads = broadcasted_payloads

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      expect(payloads.map { |p| p[:type] }).to include("completed")
      expect(conversation.messages.reload.where(role: "assistant").last.content)
        .to eq("Hello there")
    end
  end

  # ── process control block: the stamps only the job knows ───────────

  describe "the run's arrival and dispatch stamps" do
    def runner_kwargs
      captured = {}
      allow(AgentRunner).to receive(:new) do |**kwargs|
        captured.replace(kwargs)
        runner
      end
      captured
    end

    it "hands the turn's arrival and this worker's pickup time to the runner" do
      captured = runner_kwargs
      user_message.update_column(:created_at, Time.utc(2026, 11, 4, 17, 53, 20))

      perform_stream(message_id: user_message.id)

      # The run row is created inside the loop and can see neither stamp, so the
      # queue wait (READY-NEW) is only measurable because the job passes them in.
      expect(captured[:arrival_at]).to eq(user_message.reload.created_at)
      expect(captured[:dispatched_at]).to be_within(5).of(Time.current)
    end

    it "takes the arrival from the newest user turn when only content was given" do
      captured = runner_kwargs
      older = create(:message, conversation: conversation, role: "user", content: "Earlier")
      older.update_column(:created_at, Time.utc(2026, 11, 4, 17, 0, 0))
      newest = create(:message, conversation: conversation, role: "user", content: "Hi")
      newest.update_column(:created_at, Time.utc(2026, 11, 4, 17, 5, 0))

      # Conversations::StartChat posts the turn and enqueues with message_content
      # only - no message_id - and that is the normal dashboard flow.
      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      expect(captured[:arrival_at]).to eq(newest.reload.created_at)
    end

    it "still runs when the arrival cannot be resolved at all" do
      captured = runner_kwargs
      conversation.messages.delete_all

      described_class.perform_now(
        conversation_id: conversation.id, user_id: user.id, message_content: "Hi"
      )

      expect(captured[:arrival_at]).to be_nil
      expect(captured[:dispatched_at]).to be_present
    end
  end
end
