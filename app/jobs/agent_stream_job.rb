class AgentStreamJob < ApplicationJob
  queue_as :agents

  # Run budget (seconds), enforced BETWEEN chunks in #track_progress.
  #
  # This deliberately replaces `Timeout.timeout(RUN_TIMEOUT_SECONDS)`. A
  # wall-clock Timeout interrupts the run at an arbitrary instruction — it once
  # fired inside the DB write that persists the reply, rolled the placeholder
  # insert back and surfaced to the user as the meaningless "Agent error:
  # execution expired", while killing slow-but-progressing local runs anyway
  # (the raise itself is deferred while the thread sits in a C-level socket
  # read, so it landed 34–44 minutes after the budget expired).
  #
  # The budget is now only consulted at a checkpoint where nothing is
  # mid-flight, and it is a backstop rather than the primary bound: a wedged
  # provider socket does not need it, because every adapter bounds its own
  # connection (Llm::*::OPEN_TIMEOUT / READ_TIMEOUT, 120–600s) and raises
  # inside the run, which lands on the honest `failed` path below. RUN_LIMIT
  # only catches a stream that keeps producing and never reaches an answer.
  RUN_LIMIT = 45 * 60

  # Raised from the chunk callback when a run outlives its budget.
  class RunTimeout < StandardError; end

  def perform(conversation_id:, user_id:, message_content: nil, channel: :web, phone_number: nil, resume_agent_run_id: nil, message_id: nil, request_id: nil, replaces_message_id: nil)
    @request_id = request_id.presence
    # Set by Conversations::RegenerateChat: the assistant row this run replaces.
    # It survives until this run produces a real answer (see
    # #retire_superseded_message), so a failed or timed-out re-run can never
    # leave the thread with its previous reply deleted.
    @replaces_message_id = replaces_message_id.presence
    # Latch flipped exactly once a terminal frame (completed/failed) has gone
    # out, so the `ensure` safety net never double-announces.
    @terminal_broadcasted = false
    # Why this run did not succeed, when the runner reports it instead of raising
    # ({ code:, message: } set by #note_failure). Drives the terminal frame and
    # the decision to keep the reply a re-run was supposed to replace.
    @run_failure = nil
    conversation = Conversation.find(conversation_id)
    user = User.find(user_id)
    agent = conversation.agent

    Rails.logger.info "[AgentStreamJob] START conversation=#{conversation_id} user=#{user_id}#{" resume_run=#{resume_agent_run_id}" if resume_agent_run_id}#{" request_id=#{@request_id}" if @request_id}"

    # Broadcast the user's query first, on the same ordered pipeline as the
    # reply, so the query always renders above its answer. The row is also
    # handed to the runner: per-message tool selection rides in its metadata.
    source_message = nil
    if message_id.present?
      source_message = Message.find_by(id: message_id)
      broadcast_user(conversation, source_message) if source_message&.user_message?
    end

    # Create (or reuse) the streaming placeholder immediately. It is persisted
    # with an empty body and flagged via metadata["streaming"] so:
    #   * no "." character ever leaks into DB, LLM context, or DOM
    #   * the assistant bubble can render a real thinking indicator
    #   * AgentRunner's final update clears the flag in one atomic write
    # The request_id + stream_started_at let the browser bridge its optimistic
    # container to this row (idempotency) and let a refresh reconcile a run that
    # died mid-flight instead of showing perpetual "thinking".
    streaming_msg = existing_streaming_message(conversation)
    reused_placeholder = streaming_msg.present?
    streaming_msg ||= conversation.messages.create!(
      role: "assistant",
      content: "",
      metadata: streaming_metadata
    )

    # Announce the assistant response BEFORE the first status frame. This is
    # delivered over the reliable ConversationChannel (Action Cable), so the
    # live browser can adopt/bridge its optimistically-created container even if
    # the racy Turbo Stream append hasn't landed yet. Carries message_id +
    # request_id + conversation_id so the client can key exactly one container.
    broadcast_assistant_started(conversation, streaming_msg)
    # Also push the server-rendered container over Turbo for tabs/pages that
    # render from the database (the client de-dupes by request_id). Skip this
    # when we reused a row the show page already rendered (dashboard flow) —
    # appending it again would duplicate the acknowledgment in the DOM.
    broadcast_append(conversation, streaming_msg, streaming: true) unless reused_placeholder

    # Monotonic clock, so an NTP slew can neither shorten nor extend the budget.
    @run_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    runner = AgentRunner.new(
      agent: agent,
      conversation: conversation,
      user: user,
      streaming_message: streaming_msg,
      source_message: source_message
    )

    # Every chunk is a progress checkpoint: #track_progress enforces the budget
    # where nothing is mid-flight and remembers the runner's bad news, so the
    # terminal frame below can tell the truth instead of announcing completion
    # for a run that failed.
    on_chunk = lambda do |chunk|
      track_progress(chunk)
      broadcast_chunk(conversation, streaming_msg.id, chunk)
    end

    remember_outcome(
      if resume_agent_run_id
        runner.resume_plan(AgentRun.find(resume_agent_run_id), stream: true, &on_chunk)
      else
        runner.run(message_content, stream: true, &on_chunk)
      end
    )

    Rails.logger.info "[AgentStreamJob] DONE conversation=#{conversation_id}"

    # Replace streaming message with final rendered version (no cursor).
    broadcast_replace(conversation, streaming_msg.reload, streaming: false)
    mark_terminal

    if @run_failure
      # The runner rescued a provider error and wrote an honest error state into
      # the placeholder. Say `failed` — never `completed` — and leave the reply
      # this run was replacing exactly where it was, so a bad re-run costs the
      # user nothing (see #retire_superseded_message).
      payload = terminal_payload(conversation, streaming_msg.id, type: "failed")
      payload[:code] = @run_failure[:code]
      payload[:message] = @run_failure[:message]
      Rails.logger.warn "[AgentStreamJob] FAILED-RUN conversation=#{conversation_id} code=#{@run_failure[:code]}"
      ActionCable.server.broadcast("conversation:#{conversation.id}", payload)
    else
      retire_superseded_message(conversation, streaming_msg)
      ActionCable.server.broadcast("conversation:#{conversation.id}",
        terminal_payload(conversation, streaming_msg.id, type: "completed"))
    end

    if channel == :whatsapp && phone_number
      last_message = conversation.messages.where(role: "assistant").last
      WhatsappService.send_message(phone_number, last_message.content) if last_message
    end
  rescue => e
    Rails.logger.error "[AgentStreamJob] ERROR conversation=#{conversation_id} #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n") if e.backtrace

    # The rescue path must never raise: with the :inline dev adapter anything
    # thrown here (e.g. a failing auto-fixer LLM call) surfaces as a 500 page
    # in the user's browser instead of a graceful in-chat error.
    begin
      Turbo::StreamsChannel.broadcast_append_to(
        conversation,
        target: "messages-list",
        html: %(<div class="text-red-600 dark:text-red-400 text-sm p-3 rounded-lg border border-red-500/20 bg-red-500/5">Agent error: #{ERB::Util.html_escape(e.message)}</div>)
      )

      failed = { type: "failed", code: e.is_a?(RunTimeout) ? "run_timeout" : "provider_error", message: e.message, conversation_id: conversation.id }
      note_failure(e.message, code: failed[:code])
      failed[:message_id] = @streaming_msg_id if @streaming_msg_id
      failed[:request_id] = @request_id if @request_id
      ActionCable.server.broadcast("conversation:#{conversation.id}", failed)
      mark_terminal
    rescue StandardError, NameError => be
      # `conversation` itself may be nil/undefined if the failure happened
      # before it was loaded — that is still only a logging condition here.
      Rails.logger.error "[AgentStreamJob] BROADCAST-ERROR #{be.class}: #{be.message}"
    end

    # The runner clears the placeholder's streaming flag on the paths it
    # controls, but a failure that never reached a final update (a raise before
    # the loop, a run this job stopped at its checkpoint, a mid-stream crash)
    # would otherwise leave the row "live" — a refresh would keep showing the
    # thinking indicator until the stale window elapsed. Finalize it now so
    # recovery is immediate and honest.
    finalize_placeholder_if_streaming(streaming_msg)

    begin
      AgentAutoFixer.new(error: e, backtrace: e.backtrace.to_a, conversation: conversation).call
    rescue StandardError, NameError => fe
      Rails.logger.error "[AgentStreamJob] AUTO-FIX-ERROR (ignored) #{fe.class}: #{fe.message}"
    end
  ensure
    # Ultimate safety net. If neither the happy path nor the rescue emitted a
    # terminal frame — an Exception outside the StandardError rescue, or a
    # failure while broadcasting — force one so the live browser never spins
    # forever and no phantom "streaming" row is left behind.
    recover_unended_run(conversation, streaming_msg) unless @terminal_broadcasted
  end

  private

  # Flip the terminal latch so `ensure` knows a completed/failed frame went out.
  def mark_terminal
    @terminal_broadcasted = true
  end

  # Seconds this run has been alive, on the monotonic clock. Separate method so
  # a spec can drive the budget past its limit without sleeping or stubbing the
  # whole process clock.
  def elapsed_seconds
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - @run_started_at
  end

  # Checkpoint between chunks. Two responsibilities, both safe only here:
  # remember the runner's bad news, and stop a run that keeps producing without
  # ever reaching an answer.
  #
  # A chunk reporting failure is never measured against the budget: raising from
  # inside the runner's own rescue would replace its honest provider error with
  # a second, unrelated exception (and re-enter that rescue).
  def track_progress(chunk)
    if chunk[:type] == "status" && (chunk[:phase] == "failed" || chunk[:error].present?)
      note_failure(chunk[:error])
      return
    end

    elapsed = elapsed_seconds
    return if elapsed <= RUN_LIMIT

    note_failure(nil, code: "run_timeout")
    raise RunTimeout, "This run kept going for #{(elapsed / 60).round} minutes without reaching an answer, so it was stopped."
  end

  # Record why a run did not succeed. The first verdict wins, so a precise
  # internal one (run_timeout) is never overwritten by the generic message the
  # runner echoes back afterwards.
  def note_failure(message, code: "provider_error")
    @run_failure ||= { code: code, message: message.presence || "The agent run reported a failure." }
  end

  # AgentRunner rescues provider errors, writes an honest error state into the
  # placeholder and returns the bad news in its result hash instead of raising.
  # Capturing that verdict is what lets this job announce `failed` rather than
  # pretending the run completed.
  def remember_outcome(result)
    note_failure(result[:error]) if result.is_a?(Hash) && result[:error].present?
    result
  end

  # Drop the live "streaming" flag on a placeholder that is still marked live.
  # Marks an empty body as `empty_response` so the finalized render shows an
  # honest recovery state rather than a blank bubble. Never clobbers a real
  # answer that already cleared the flag (guarded by `streaming?`).
  def finalize_placeholder_if_streaming(message)
    return unless message&.persisted?

    fresh = message.reload
    return unless fresh.streaming?

    meta = fresh.metadata.is_a?(Hash) ? fresh.metadata.dup : {}
    meta.delete("streaming")
    meta["stream_started_at"] ||= Time.current.utc.iso8601
    meta["empty_response"] = true if fresh.content.to_s.empty?
    fresh.update!(metadata: meta)
  rescue StandardError, NameError => e
    Rails.logger.error "[AgentStreamJob] PLACEHOLDER-FINALIZE-ERROR #{e.class}: #{e.message}"
  end

  # Delete the reply this run replaced — but only once the new answer is real
  # (finalized, non-empty, no metadata["error"]). Conversations::RegenerateChat
  # deliberately leaves the old row in place while the re-run is in flight, so a
  # provider failure, a stall or a timeout costs the user nothing: the thread
  # keeps the answer they already had. Only a genuine replacement retires it,
  # and the removal is broadcast so the live DOM matches the database.
  def retire_superseded_message(conversation, message)
    return unless @replaces_message_id

    fresh = message.reload
    return if fresh.streaming?
    return if fresh.content.to_s.strip.empty?
    return if fresh.metadata.is_a?(Hash) && fresh.metadata["error"].present?

    superseded = Message.where(role: "assistant").find_by(id: @replaces_message_id)
    return unless superseded

    superseded.destroy!
    Turbo::StreamsChannel.broadcast_remove_to(
      conversation, target: "assistant-message-#{superseded.id}"
    )
  rescue StandardError, NameError => e
    # Bookkeeping must never turn a finished answer into an error bubble.
    Rails.logger.error "[AgentStreamJob] SUPERSEDED-RETIRE-ERROR #{e.class}: #{e.message}"
  end

  # Emit a terminal `failed` frame (and finalize the row) when a run exited
  # without one. Best-effort: everything is guarded so this never raises out of
  # the `ensure` clause.
  def recover_unended_run(conversation, streaming_msg)
    return if conversation.nil?

    finalize_placeholder_if_streaming(streaming_msg)
    payload = {
      type: "failed",
      code: "run_incomplete",
      message: "The response did not complete. Please try again.",
      conversation_id: conversation.id
    }
    payload[:message_id] = streaming_msg&.id
    payload[:request_id] = @request_id if @request_id
    ActionCable.server.broadcast("conversation:#{conversation.id}", payload)
    broadcast_replace(conversation, streaming_msg.reload, streaming: false) if streaming_msg&.persisted?
    @terminal_broadcasted = true
  rescue StandardError, NameError => e
    Rails.logger.error "[AgentStreamJob] RECOVER-ERROR #{e.class}: #{e.message}"
  end

  # A retried enqueue (Solid Queue at-least-once) must never stack two live
  # placeholders for the same request. Reuse the in-flight row when present.
  def existing_streaming_message(conversation)
    return nil unless @request_id

    conversation.messages.where(role: "assistant")
      .where("metadata->>'request_id' = ?", @request_id)
      .order(created_at: :desc)
      .find { |m| m.streaming? }
  end

  def streaming_metadata
    meta = { "streaming" => true, "stream_started_at" => Time.current.utc.iso8601 }
    meta["request_id"] = @request_id if @request_id
    meta
  end

  def terminal_payload(conversation, message_id, type:)
    payload = { type: type, message_id: message_id, conversation_id: conversation.id }
    payload[:request_id] = @request_id if @request_id
    payload
  end

  def broadcast_assistant_started(conversation, message)
    @streaming_msg_id = message.id
    payload = {
      type: "assistant_started",
      message_id: message.id,
      conversation_id: conversation.id,
      stream_started_at: message.metadata["stream_started_at"]
    }
    payload[:request_id] = @request_id if @request_id
    ActionCable.server.broadcast("conversation:#{conversation.id}", payload)
  end

  def broadcast_user(conversation, message)
    html = ApplicationController.render(partial: "messages/message", locals: { message: message })
    Turbo::StreamsChannel.broadcast_append_to(conversation, target: "messages-list", html: html)
  end

  def broadcast_append(conversation, message, streaming:)
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: message, streaming: streaming })
    Turbo::StreamsChannel.broadcast_append_to(conversation, target: "messages-list", html: html)
  end

  def broadcast_replace(conversation, message, streaming:)
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: message, streaming: streaming })
    Turbo::StreamsChannel.broadcast_replace_to(conversation, target: "assistant-message-#{message.id}", html: html)
  end

  def broadcast_chunk(conversation, message_id, chunk)
    @streaming_msg_id ||= message_id
    stream = "conversation:#{conversation.id}"
    case chunk[:type]
    when "content_delta"
      payload = { type: "content_delta", text: chunk[:text], message_id: message_id, conversation_id: conversation.id }
      payload[:request_id] = @request_id if @request_id
      ActionCable.server.broadcast(stream, payload)
    when "status"
      payload = { type: "status", phase: chunk[:phase], message_id: message_id, conversation_id: conversation.id }
      payload[:error] = chunk[:error] if chunk[:error]
      payload[:request_id] = @request_id if @request_id
      ActionCable.server.broadcast(stream, payload)
    when "tool_call"
      payload = { type: "tool_call", tool: chunk[:tool], result: chunk[:result], message_id: message_id, conversation_id: conversation.id }
      payload[:request_id] = @request_id if @request_id
      ActionCable.server.broadcast(stream, payload)
    end
  end
end
