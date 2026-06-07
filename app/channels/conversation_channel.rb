# Conversation Channel - Streams messages and agent responses for a specific conversation.
class ConversationChannel < ApplicationCable::Channel
  def subscribed
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
    return unless data["content"].present?

    message = @conversation.messages.create!(
      role: "user",
      content: data["content"]
    )

    # Queue agent response.
    AgentStreamJob.perform_later(
      conversation_id: @conversation.id,
      user_id: current_user.id,
      message_content: message.content
    )
  end

  # Stop generation.
  def stop(_data)
    @conversation.update(status: "paused")
  end
end
