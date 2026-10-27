require "timeout"

class AgentStreamJob < ApplicationJob
  queue_as :agents

  # Runaway guard (seconds). Comfortably above the slowest legitimate
  # generation (local models can take minutes per the adapter read timeouts),
  # so it only trips when a provider socket has truly wedged. On trip, Timeout
  # raises; whatever error path catches it (the runner's internal rescue or
  # this job's) the placeholder is finalized and the browser stops "thinking"
  # instead of spinning forever.
  RUN_TIMEOUT_SECONDS = 15 * 60

  def perform(conversation_id:, user_id:, message_content: nil, channel: :web, phone_number: nil, resume_agent_run_id: nil, message_id: nil, request_id: nil)
    @request_id = request_id.presence
    # Latch flipped exactly once a terminal frame (completed/failed) has gone
    # out, so the `ensure` safety net never double-announces.
    @terminal_broadcasted = false
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

    runner = AgentRunner.new(
      agent: agent,
      conversation: conversation,
      user: user,
      streaming_message: streaming_msg,
      source_message: source_message
    )

    # Bound the whole run so a wedged provider call can never pin this worker
    # (and leave a placeholder spinning with no terminal frame) indefinitely.
    Timeout.timeout(RUN_TIMEOUT_SECONDS) do
      if resume_agent_run_id
        agent_run = AgentRun.find(resume_agent_run_id)
        runner.resume_plan(agent_run, stream: true) do |chunk|
          broadcast_chunk(conversation, streaming_msg.id, chunk)
        end
      else
        runner.run(message_content, stream: true) do |chunk|
          broadcast_chunk(conversation, streaming_msg.id, chunk)
        end
      end
    end

    Rails.logger.info "[AgentStreamJob] DONE conversation=#{conversation_id}"

    # Replace streaming message with final rendered version (no cursor).
    broadcast_replace(conversation, streaming_msg.reload, streaming: false)
    mark_terminal
    ActionCable.server.broadcast("conversation:#{conversation.id}",
      terminal_payload(conversation, streaming_msg.id, type: "completed"))

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

      failed = { type: "failed", code: "provider_error", message: e.message, conversation_id: conversation.id }
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
    # the loop, a Timeout the runner couldn't swallow, a mid-stream crash) would
    # otherwise leave the row "live" — a refresh would keep showing the thinking
    # indicator until the stale window elapsed. Finalize it now so recovery is
    # immediate and honest.
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
