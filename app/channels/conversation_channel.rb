# Conversation Channel - Streams messages and agent responses for a specific conversation.
class ConversationChannel < ApplicationCable::Channel
  def subscribed
    return close_inactive_session! unless active_auth_session?

    @conversation = Conversation.find(params[:conversation_id])

    # Only allow subscribed users.
    if @conversation.user_id != current_user.id
      reject
      return
    end

    stream_from "conversation:#{@conversation.id}"
  end

  def unsubscribed
    stop_all_streams
  end

  # Receive messages from the client.
  def speak(data)
    return close_inactive_session! unless active_auth_session?

    admission = Conversations::TurnAdmission.call(
      conversation: @conversation,
      user: current_user,
      params: data,
      requested_mode: data["admission"]
    )
    payload = {
      type: admission.status == :invalid ? "message_rejected" : "message_admitted",
      conversation_id: @conversation.id,
      request_id: admission.request_id,
      admission: admission.status,
      queued_count: admission.queued_count
    }
    payload[:errors] = admission.errors if admission.status == :invalid
    ActionCable.server.broadcast("conversation:#{@conversation.id}", payload)
  rescue Llm::ModelCatalogue::Error => e
    ActionCable.server.broadcast("conversation:#{@conversation.id}",
      type: "message_rejected", conversation_id: @conversation.id, errors: [ e.message ])
  end

  # Stop generation.
  def stop(_data)
    return close_inactive_session! unless active_auth_session?

    runs = @conversation.runs.active.to_a
    plans = @conversation.agent_runs.active.update_all(status: "interrupted")
    live = @conversation.messages.where(role: "assistant").order(created_at: :desc).limit(5)
      .find { |message| message.streaming? && !message.stale_streaming? }
    if live
      live.with_lock do
        metadata = live.metadata.is_a?(Hash) ? live.metadata : {}
        live.update!(metadata: metadata.merge("stop_requested" => true))
      end
    end
    runs.each(&:cancel!)
    if runs.any? || plans.positive? || live
      payload = { type: "stopped", conversation_id: @conversation.id }
      payload[:message_id] = live.id if live
      payload[:request_id] = live.metadata["request_id"] if live&.metadata&.dig("request_id")
      ActionCable.server.broadcast("conversation:#{@conversation.id}", payload)
    end
    Conversations::TurnAdmission.publish_tasks(@conversation)
  end
end
