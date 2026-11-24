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
    return head :forbidden unless WhatsappService.valid_signature?(payload, request.headers["X-Hub-Signature-256"])

    WhatsappService.handle_webhook(payload)
    render json: { received: true }, status: :ok
  end
end
