# frozen_string_literal: true

require "httparty"

module Integrations
  module Resend
    # Real POST https://api.resend.com/emails with the org's re_ key.
    class SendEmail
      extend Integrations::HttpSupport

      ENDPOINT = "https://api.resend.com/emails"

      def self.call(integration:, arguments:, context: {})
        key = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if key.blank?

        creds = integration.decrypted_credentials.is_a?(Hash) ? integration.decrypted_credentials : {}
        from = arguments["from"].to_s.strip
        from = creds["from_address"].to_s.strip if from.empty?
        to = arguments["to"].to_s.strip
        subject = arguments["subject"].to_s.strip
        body = arguments["body"].to_s.strip

        if to.empty? || subject.empty? || body.empty?
          return { ok: false, error_code: "invalid_request", errors: [ "to, subject and body are required" ] }
        end
        return { ok: false, error_code: "missing_sender" } if from.empty?

        response = HTTParty.post(
          ENDPOINT,
          headers: { "Authorization" => "Bearer #{key}", "Content-Type" => "application/json" },
          body: { from: from, to: [ to ], subject: subject, text: body }.to_json,
          timeout: timeout_for(integration)
        )
        parsed = parse_json(response)

        if http_ok?(response.code) && parsed["id"].present?
          { ok: true, provider: "resend", email_id: parsed["id"], to: to }
        else
          { ok: false, error_code: "provider_error", provider_error: email_error(parsed).truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end

      def self.email_error(body)
        body["message"].presence || body["error"].presence || "HTTP request failed"
      end
      private_class_method :email_error
    end
  end
end
