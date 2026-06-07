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

    last_assistant = conversation.messages.where(role: "assistant").last
    return unless last_assistant

    last_assistant.destroy!
    last_user = conversation.messages.where(role: "user").last
    return unless last_user

    AgentStreamJob.perform_later(
      conversation_id: conversation.id,
      user_id: current_user.id,
      message_content: last_user.content
    )
  end
end
