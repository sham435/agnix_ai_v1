# frozen_string_literal: true

require "httparty"

module Integrations
  module Whatsapp
    # Sends via the WhatsApp Cloud API using the ORG's own integration
    # credentials (bearer token + phone_number_id from config) — the same
    # request shape WhatsappService uses for the platform-level number.
    class SendMessage
      extend Integrations::HttpSupport

      BASE_URL = "https://graph.facebook.com/v20.0"

      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

        phone_id = integration.whatsapp_phone_number_id
        return { ok: false, error_code: "missing_phone_number_id" } if phone_id.blank?

        to = arguments["to"].to_s.gsub(/[^\d]/, "")
        text = arguments["text"].to_s.strip
        if to.empty? || text.empty?
          return { ok: false, error_code: "invalid_request", errors: [ "to and text are required" ] }
        end

        response = HTTParty.post(
          "#{BASE_URL}/#{phone_id}/messages",
          headers: bearer_headers(token),
          body: {
            messaging_product: "whatsapp",
            recipient_type: "individual",
            to: to,
            type: "text",
            text: { body: text.truncate(4096) }
          }.to_json,
          timeout: timeout_for(integration)
        )
        parsed = parse_json(response)

        if http_ok?(response.code)
          message_id = parsed.dig("messages", 0, "id")
          { ok: true, provider: "whatsapp", message_id: message_id, to: to }
        else
          detail = parsed.dig("error", "message").to_s.presence || "WhatsApp returned HTTP #{response.code}"
          { ok: false, error_code: "provider_error", provider_error: detail.truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
