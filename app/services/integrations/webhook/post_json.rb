# frozen_string_literal: true

require "httparty"
require "uri"

module Integrations
  module Webhook
    # Generic outbound plugin: POSTs a JSON payload to the endpoint the org
    # configured on the integration (store_accessor webhook_url). Response
    # bodies are echoed truncated; the URL itself may carry a shared secret
    # in its query string, so it never appears in results.
    class PostJson
      extend Integrations::HttpSupport

      def self.call(integration:, arguments:, context: {})
        url = integration.webhook_url.to_s.strip
        return { ok: false, error_code: "missing_endpoint" } if url.empty?
        return { ok: false, error_code: "invalid_endpoint" } unless absolute_http_url?(url)

        payload = arguments["payload"]
        return { ok: false, error_code: "invalid_request", errors: [ "payload must be a JSON object" ] } unless payload.is_a?(Hash)

        event = arguments["event"].to_s.strip
        body = event.empty? ? payload : payload.merge("event" => event)

        response = HTTParty.post(
          url,
          headers: { "Content-Type" => "application/json", "User-Agent" => "ShamsAI-Plugins" },
          body: body.to_json,
          timeout: timeout_for(integration)
        )

        snippet = response.body.to_s.truncate(300)
        if http_ok?(response.code)
          { ok: true, provider: "webhook", status: response.code, response: snippet }
        else
          { ok: false, error_code: "endpoint_error", status: response.code, response: snippet }
        end
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
