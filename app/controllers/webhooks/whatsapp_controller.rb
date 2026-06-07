# Webhooks controller for WhatsApp Cloud API.
class Webhooks::WhatsappController < ApplicationController
  skip_before_action :verify_authenticity_token

  # Webhook verification (GET).
  def verify
    challenge = WhatsappService.verify_webhook(
      mode: params["hub.mode"],
      token: params["hub.verify_token"],
      challenge: params["hub.challenge"]
    )

    if challenge
      render plain: challenge, status: :ok
    else
      render plain: "Forbidden", status: :forbidden
    end
  end

  # Webhook events (POST).
  def create
    payload = request.body.read
    results = WhatsappService.handle_webhook(payload)

    # Process inbound messages through the agent system.
    results.each do |result|
      next unless result[:user] && result[:content]

      # Find or create a conversation for this WhatsApp user.
      conversation = Conversation.find_or_create_by!(
        user: result[:user],
        agent: Agent.where(is_active: true).first # Default agent.
      ) do |conv|
        conv.title = "WhatsApp Chat #{result[:phone_number]}"
      end

      # Create message and queue agent response.
      conversation.messages.create!(
        role: "user",
        content: result[:content]
      )

      AgentStreamJob.perform_later(
        conversation_id: conversation.id,
        user_id: result[:user].id,
        message_content: result[:content],
        channel: :whatsapp,
        phone_number: result[:phone_number]
      )
    end

    render json: { received: true }, status: :ok
  end
end
