# frozen_string_literal: true

require "net/http"

module Integrations
  class WebSearch
    ENDPOINT = "https://api.tavily.com/search"

    def self.call(arguments:, integration: nil, context: {}, api_key: nil, timeout: 20)
      return { ok: false, error_code: "integration_inactive" } if integration && !integration.is_active?
      if integration && (context.key?(:user) || context.key?(:user_id))
        user = Agents::ToolRegistry::ToolContext.user_for(context)
        organization = ToolIntegration.authorized_organization_for(user, context)
        return { ok: false, error_code: "not_authorized" } unless organization&.id == integration.organization_id
      end
      query = arguments["query"]
      limit = arguments.fetch("num_results", arguments.fetch("max_results", 5))
      unless query.is_a?(String) && query.strip.present? && query.length <= 512 && limit.is_a?(Integer) && (1..10).cover?(limit)
        return { ok: false, error_code: "invalid_request" }
      end
      token = integration&.api_key.presence || api_key
      return { ok: false, error_code: "missing_credentials" } if token.blank?
      return { ok: false, error_code: "invalid_credentials" } unless token.is_a?(String) && token.match?(/\A[^\s\x00-\x1f\x7f]{1,512}\z/)

      uri = URI(ENDPOINT)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request.body = { query: query.strip, max_results: limit, include_answer: false, include_raw_content: false }.to_json
      parsed = BoundedJsonRequest.call(uri: uri, request: request, timeout: timeout)
      return { ok: false, error_code: "provider_error" } unless parsed["results"].is_a?(Array)

      sources = parsed["results"].first(limit).filter_map do |item|
        next unless item.is_a?(Hash) && item["url"].is_a?(String) && item["url"].length <= 2048

        begin
          url = URI.parse(item["url"])
          next unless %w[http https].include?(url.scheme) && url.host.present? && url.userinfo.nil?
        rescue URI::InvalidURIError
          next
        end
        { title: item["title"].to_s.first(300), url: item["url"], snippet: item["content"].to_s.first(2000) }
      end
      { ok: true, provider: "tavily", sources: sources, results: sources }
    rescue StandardError
      { ok: false, error_code: "provider_error" }
    end
  end
end
