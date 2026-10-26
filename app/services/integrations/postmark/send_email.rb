# frozen_string_literal: true

module Integrations
  module Postmark
    # Real direct send through the org's own Postmark server token — same
    # client EmailService uses, but scoped to the integration's credentials
    # instead of the global Rails credentials token.
    class SendEmail
      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

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

        info = ::Postmark::ApiClient.new(token).deliver(
          "From" => from, "To" => to, "Subject" => subject, "TextBody" => body
        )
        # postmark 1.25 hands back a symbol-keyed hash; older shapes exposed an
        # info object / raw MessageID key.
        message_id = if info.respond_to?(:message_id)
          info.message_id
        elsif info.is_a?(Hash)
          info[:message_id] || info["message_id"] || info["MessageID"]
        end
        { ok: true, provider: "postmark", email_id: message_id, to: to }
      rescue ::Postmark::Error => e
        { ok: false, error_code: "provider_error", provider_error: e.message.to_s.truncate(200) }
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
