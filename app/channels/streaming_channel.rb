# Streaming Channel - Receives streamed content from agent runs.
class StreamingChannel < ApplicationCable::Channel
  def subscribed
    return close_inactive_session! unless active_auth_session?

    # Stream from the user-specific channel.
    stream_from "streaming:#{current_user.id}" if current_user
  end

  def unsubscribed
    # Any cleanup needed.
  end

  # Receive messages from the client.
  def receive(data)
    return close_inactive_session! unless active_auth_session?

    case data["action"]
    when "stop_generation"
      # Signal the agent runner to stop.
      stop_generation(data["conversation_id"])
    when "regenerate"
      # Regenerate the last response.
      regenerate_last_response(data["conversation_id"])
    end
  end

  private

  def stop_generation(conversation_id)
    conversation = current_user.conversations.find_by(id: conversation_id)
    return unless conversation

    runs = conversation.runs.active.to_a
    plans = conversation.agent_runs.active.update_all(status: "interrupted")
    live = conversation.messages.where(role: "assistant").order(created_at: :desc).limit(5)
      .find { |message| message.streaming? && !message.stale_streaming? }
    if live
      live.with_lock do
        metadata = live.metadata.is_a?(Hash) ? live.metadata : {}
        live.update!(metadata: metadata.merge("stop_requested" => true))
      end
    end
    runs.each(&:cancel!)
    ActionCable.server.broadcast(
      "streaming:#{current_user.id}",
      { type: "stopped" }
    ) if runs.any? || plans.positive? || live
    Conversations::TurnAdmission.publish_tasks(conversation)
  end

  def regenerate_last_response(conversation_id)
    conversation = current_user.conversations.find_by(id: conversation_id)
    return unless conversation

    # One path with the HTTP buttons: nothing is destroyed here, and a
    # conversation with a live run is refused instead of stacking a second
    # concurrent AgentStreamJob on it.
    outcome = Conversations::RegenerateChat.call(conversation: conversation, user: current_user)
    ActionCable.server.broadcast(
      "streaming:#{current_user.id}",
      { type: "regenerate_outcome", status: outcome.status.to_s, message: outcome.message,
        conversation_id: conversation.id }
    )
  end
end
