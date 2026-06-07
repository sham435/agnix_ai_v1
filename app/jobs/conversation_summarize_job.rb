# Conversation Summarization Job - Compresses long conversations.
class ConversationSummarizeJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    return if conversation.messages.count < 20

    # Get early messages.
    early_messages = conversation.messages.order(created_at: :asc).limit(15)

    # Summarize using the agent's LLM.
    agent = conversation.agent
    client = agent.llm_client

    response = client.chat(
      messages: [
        { role: "system", content: "Summarize this conversation in 3-5 sentences, preserving key facts and decisions." },
        { role: "user", content: early_messages.map(&:content).join("\n\n") }
      ],
      tools: []
    )

    # Save summary as a system message.
    conversation.messages.create!(
      role: "system",
      content: "[Summary] #{response[:content]}",
      tokens: response[:tokens]
    )

    # Delete the early messages.
    early_messages.destroy_all

    Rails.logger.info "Summarized conversation #{conversation_id}"
  end
end
