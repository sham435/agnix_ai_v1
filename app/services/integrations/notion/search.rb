# frozen_string_literal: true

require "httparty"

module Integrations
  module Notion
    # Real Notion search API call against the org's internal integration
    # secret. Only pages/databases explicitly shared with the integration
    # are visible — that is Notion's own permission boundary.
    class Search
      extend Integrations::HttpSupport

      ENDPOINT = "https://api.notion.com/v1/search"
      NOTION_VERSION = "2022-06-28"
      DEFAULT_LIMIT = 10
      MAX_LIMIT = 50

      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

        limit = arguments["limit"].to_i
        limit = DEFAULT_LIMIT if limit <= 0
        limit = [ limit, MAX_LIMIT ].min

        payload = { page_size: limit }
        query = arguments["query"].to_s.strip
        payload[:query] = query unless query.empty?

        response = HTTParty.post(
          ENDPOINT,
          headers: bearer_headers(token, "Notion-Version" => NOTION_VERSION),
          body: payload.to_json,
          timeout: timeout_for(integration)
        )
        parsed = parse_json(response)

        if http_ok?(response.code) && parsed["results"].is_a?(Array)
          {
            ok: true, provider: "notion",
            results: parsed["results"].first(limit).map do |item|
              { id: item["id"], object: item["object"], title: extract_title(item) }
            end
          }
        else
          detail = parsed["message"].to_s.presence || "Notion returned HTTP #{response.code}"
          { ok: false, error_code: "provider_error", provider_error: detail.truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end

      # Notion titles live in a "title"-typed property array; databases also
      # nest it under "title". Anything without a readable title stays nil.
      def self.extract_title(item)
        properties = item["properties"]
        title_prop = properties.is_a?(Hash) ? properties.values.find { |v| v.is_a?(Hash) && v["type"] == "title" } : nil
        rich = title_prop&.[]("title")
        return nil unless rich.is_a?(Array)

        text = rich.filter_map { |part| part["plain_text"] }.join
        text.presence
      rescue StandardError
        nil
      end
      private_class_method :extract_title
    end
  end
end
