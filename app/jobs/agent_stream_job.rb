# Agent Stream Job - Runs the agent and streams responses via Action Cable.
class AgentStreamJob < ApplicationJob
  queue_as :agents

  def perform(conversation_id:, user_id:, message_content:, channel: :web, phone_number: nil)
    conversation = Conversation.find(conversation_id)
    user = User.find(user_id)
    agent = conversation.agent

    runner = AgentRunner.new(
      agent: agent,
      conversation: conversation,
      user: user
    )

    # Broadcast chunks to the conversation channel.
    runner.run(message_content, stream: true) do |chunk|
      case chunk[:type]
      when "chunk"
        ActionCable.server.broadcast(
          "conversation:#{conversation.id}",
          { type: "content", content: chunk[:content], full: chunk[:full] }
        )
      when "tool_call"
        ActionCable.server.broadcast(
          "conversation:#{conversation.id}",
          { type: "tool_call", tool: chunk[:tool], result: chunk[:result] }
        )
      end
    end

    # Send WhatsApp response if via WhatsApp.
    if channel == :whatsapp && phone_number
      last_message = conversation.messages.where(role: "assistant").last
      WhatsappService.send_message(phone_number, last_message.content) if last_message
    end
  end
end
