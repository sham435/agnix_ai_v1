class AgentStreamJob < ApplicationJob
  queue_as :agents

  def perform(conversation_id:, user_id:, message_content: nil, channel: :web, phone_number: nil, resume_agent_run_id: nil, message_id: nil, request_id: nil)
    @request_id = request_id.presence
    conversation = Conversation.find(conversation_id)
    user = User.find(user_id)
    agent = conversation.agent

    Rails.logger.info "[AgentStreamJob] START conversation=#{conversation_id} user=#{user_id}#{" resume_run=#{resume_agent_run_id}" if resume_agent_run_id}#{" request_id=#{@request_id}" if @request_id}"

    # Broadcast the user's query first, on the same ordered pipeline as the
    # reply, so the query always renders above its answer.
    if message_id.present?
      user_message = Message.find_by(id: message_id)
      broadcast_user(conversation, user_message) if user_message&.user_message?
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
      streaming_message: streaming_msg
    )

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

    Rails.logger.info "[AgentStreamJob] DONE conversation=#{conversation_id}"

    # Replace streaming message with final rendered version (no cursor).
    broadcast_replace(conversation, streaming_msg.reload, streaming: false)

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
        html: %(<div class="text-red-400 text-sm p-3 rounded-lg border border-red-500/20 bg-red-500/5">Agent error: #{ERB::Util.html_escape(e.message)}</div>)
      )

      failed = { type: "failed", code: "provider_error", message: e.message, conversation_id: conversation.id }
      failed[:message_id] = @streaming_msg_id if @streaming_msg_id
      failed[:request_id] = @request_id if @request_id
      ActionCable.server.broadcast("conversation:#{conversation.id}", failed)
    rescue StandardError, NameError => be
      # `conversation` itself may be nil/undefined if the failure happened
      # before it was loaded — that is still only a logging condition here.
      Rails.logger.error "[AgentStreamJob] BROADCAST-ERROR #{be.class}: #{be.message}"
    end

    begin
      AgentAutoFixer.new(error: e, backtrace: e.backtrace.to_a, conversation: conversation).call
    rescue StandardError, NameError => fe
      Rails.logger.error "[AgentStreamJob] AUTO-FIX-ERROR (ignored) #{fe.class}: #{fe.message}"
    end
  end

  private

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
