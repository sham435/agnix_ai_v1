# frozen_string_literal: true

require "httparty"

module Integrations
  module Slack
    # Real chat.postMessage call with the org's bot token. Slack answers 200
    # even on business errors, so the response body's "ok" flag decides.
    class PostMessage
      extend Integrations::HttpSupport

      ENDPOINT = "https://slack.com/api/chat.postMessage"

      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

        channel = arguments["channel"].to_s.strip
        text = arguments["text"].to_s.strip
        if channel.empty? || text.empty?
          return { ok: false, error_code: "invalid_request", errors: [ "channel and text are required" ] }
        end

        response = HTTParty.post(
          ENDPOINT,
          headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" },
          body: { channel: channel, text: text }.to_json,
          timeout: timeout_for(integration)
        )
        body = parse_json(response)

        if http_ok?(response.code) && body["ok"]
          { ok: true, provider: "slack", channel: body["channel"], message_id: body["ts"] }
        else
          { ok: false, error_code: "provider_error", provider_error: body["error"].to_s.truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
