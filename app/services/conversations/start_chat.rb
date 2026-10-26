# frozen_string_literal: true

# Phase 5b — The single code path for "start a conversation with an agent".
# Extracted verbatim from ConversationsController#create (dashboard composer)
# so Explore reuses the EXACT same contract: title truncation, the user
# message, the streaming assistant placeholder (metadata["streaming"],
# "stream_started_at", "request_id" — the placeholder contract is forbidden
# to drift), and the AgentStreamJob hand-off. Any future fix to chat startup
# lands here and reaches every entry point at once.
module Conversations
  module StartChat
    class << self
      # content: first user message text (nil/blank = empty conversation).
      # title: overrides the content-derived title (Explore passes
      # "New conversation with <agent>").
      def call(user:, agent:, content: nil, title: nil)
        conversation = user.conversations.create!(
          agent: agent,
          title: title.presence || content.to_s.truncate(50, omission: "...")
        )
        return conversation if content.blank?

        message = conversation.messages.create!(role: "user", content: content)

        # Provision the streaming assistant placeholder NOW and hand its
        # request_id to the job, so the redirected show page renders the
        # acknowledgment immediately and the job reuses this exact row
        # instead of creating a second placeholder.
        request_id = SecureRandom.uuid
        conversation.messages.create!(
          role: "assistant",
          content: "",
          metadata: {
            "streaming" => true,
            "stream_started_at" => Time.current.utc.iso8601,
            "request_id" => request_id
          }
        )

        AgentStreamJob.perform_later(
          conversation_id: conversation.id,
          user_id: user.id,
          message_content: message.content,
          request_id: request_id
        )

        conversation
      end
    end
  end
end
