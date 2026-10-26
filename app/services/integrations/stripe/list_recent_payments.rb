# frozen_string_literal: true

module Integrations
  module Stripe
    # Recent charges via the stripe gem with a per-request api_key — the
    # org's connected key is used, never the global Stripe config.
    class ListRecentPayments
      DEFAULT_LIMIT = 10
      MAX_LIMIT = 50

      def self.call(integration:, arguments:, context: {})
        key = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if key.blank?

        limit = arguments["limit"].to_i
        limit = DEFAULT_LIMIT if limit <= 0
        limit = [ limit, MAX_LIMIT ].min

        charges = ::Stripe::Charge.list({ limit: limit }, { api_key: key })
        {
          ok: true,
          provider: "stripe",
          payments: charges.data.map do |charge|
            {
              id: charge.id,
              amount: charge.amount,
              currency: charge.currency,
              status: charge.status,
              created: Time.at(charge.created.to_i).utc.iso8601
            }
          end
        }
      rescue ::Stripe::StripeError => e
        { ok: false, error_code: "provider_error", provider_error: e.message.to_s.truncate(200) }
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
