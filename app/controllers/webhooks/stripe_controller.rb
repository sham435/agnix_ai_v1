# Webhooks controller for Stripe.
class Webhooks::StripeController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    payload = request.body.read
    signature = request.env["HTTP_STRIPE_SIGNATURE"]

    begin
      event = StripeService.handle_webhook(payload, signature)
      render json: { received: true }, status: :ok
    rescue JSON::ParserError
      render json: { error: "Invalid JSON" }, status: :bad_request
    rescue Stripe::SignatureVerificationError
      render json: { error: "Invalid signature" }, status: :bad_request
    rescue => e
      Rails.logger.error "Stripe webhook error: #{e.message}"
      render json: { error: "Processing error" }, status: :unprocessable_entity
    end
  end
end
