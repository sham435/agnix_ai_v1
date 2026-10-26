# frozen_string_literal: true

module Integrations
  # Shared plumbing for plugin executors (integration_agent ownership):
  # bounded request timeouts from the integration's config and safe JSON
  # parsing of provider responses. Mixed in via `extend`.
  module HttpSupport
    DEFAULT_TIMEOUT = 15
    MAX_TIMEOUT = 30

    def timeout_for(integration)
      raw = integration.timeout.to_s.strip
      seconds = raw.match?(/\A\d+\z/) ? raw.to_i : DEFAULT_TIMEOUT
      seconds.clamp(1, MAX_TIMEOUT)
    end

    def parse_json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError, TypeError
      {}
    end

    def http_ok?(code)
      code.to_i.between?(200, 299)
    end

    def bearer_headers(token, extra = {})
      { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }.merge(extra)
    end
  end
end
