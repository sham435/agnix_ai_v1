# Streaming Channel - Receives streamed content from agent runs.
class StreamingChannel < ApplicationCable::Channel
  def subscribed
    # Stream from the user-specific channel.
    stream_from "streaming:#{current_user.id}" if current_user
  end

  def unsubscribed
    # Any cleanup needed.
  end

  # Receive messages from the client.
  def receive(data)
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

    conversation.update(status: "paused")
    ActionCable.server.broadcast(
      "streaming:#{current_user.id}",
      { type: "stopped" }
    )
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
