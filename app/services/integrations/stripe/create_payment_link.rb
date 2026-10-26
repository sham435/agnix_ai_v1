# frozen_string_literal: true

require "uri"

module Integrations
  module Stripe
    # One-off Checkout session with inline price data — a real, sendable
    # payment link created on the org's connected Stripe account (per-request
    # api_key), no dashboard price setup required.
    class CreatePaymentLink
      DEFAULT_CURRENCY = "usd".freeze

      def self.call(integration:, arguments:, context: {})
        key = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if key.blank?

        amount = arguments["amount_cents"].to_i
        currency = arguments["currency"].to_s.strip.downcase
        currency = DEFAULT_CURRENCY if currency.empty?
        title = arguments["description"].to_s.strip
        success_url = arguments["success_url"].to_s.strip

        errors = []
        errors << "amount_cents must be a positive integer" unless amount.positive?
        errors << "currency must be a three-letter ISO code" unless currency.match?(/\A[a-z]{3}\z/)
        errors << "description is required" if title.empty?
        errors << "success_url must be an absolute http(s) URL" unless absolute_http_url?(success_url)
        return { ok: false, error_code: "invalid_request", errors: errors } if errors.any?

        session = ::Stripe::Checkout::Session.create({
          mode: "payment",
          success_url: success_url,
          line_items: [ {
            quantity: 1,
            price_data: {
              currency: currency,
              unit_amount: amount,
              product_data: { name: title }
            }
          } ]
        }, { api_key: key })

        { ok: true, provider: "stripe", checkout_url: session.url, session_id: session.id,
          amount: amount, currency: currency }
      rescue ::Stripe::StripeError => e
        { ok: false, error_code: "provider_error", provider_error: e.message.to_s.truncate(200) }
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end

      def self.absolute_http_url?(value)
        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
      private_class_method :absolute_http_url?
    end
  end
end
