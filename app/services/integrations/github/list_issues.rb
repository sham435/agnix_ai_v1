# frozen_string_literal: true

require "httparty"
require "cgi"

module Integrations
  module Github
    # Real GET /repos/{owner}/{repo}/issues with the org's PAT.
    class ListIssues
      extend Integrations::HttpSupport

      API_BASE = "https://api.github.com"
      VERSION_HEADERS = {
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28"
      }.freeze
      STATES = %w[open closed all].freeze
      DEFAULT_LIMIT = 20
      MAX_LIMIT = 100

      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

        owner = arguments["owner"].to_s.strip
        repo = arguments["repo"].to_s.strip
        if owner.empty? || repo.empty?
          return { ok: false, error_code: "invalid_request", errors: [ "owner and repo are required" ] }
        end

        state = arguments["state"].to_s.strip.downcase
        state = "open" if state.empty?
        return { ok: false, error_code: "invalid_request", errors: [ "state must be open, closed or all" ] } unless STATES.include?(state)

        limit = arguments["limit"].to_i
        limit = DEFAULT_LIMIT if limit <= 0
        limit = [ limit, MAX_LIMIT ].min

        response = HTTParty.get(
          "#{API_BASE}/repos/#{CGI.escape(owner)}/#{CGI.escape(repo)}/issues?state=#{state}&per_page=#{limit}&sort=created&direction=desc",
          headers: bearer_headers(token, VERSION_HEADERS),
          timeout: timeout_for(integration)
        )
        parsed = parse_json(response)

        if http_ok?(response.code) && parsed.is_a?(Array)
          {
            ok: true, provider: "github",
            issues: parsed.first(limit).map do |issue|
              {
                number: issue["number"], title: issue["title"], state: issue["state"],
                html_url: issue["html_url"], updated_at: issue["updated_at"]
              }
            end
          }
        else
          detail = parsed.is_a?(Hash) ? parsed["message"].to_s : ""
          detail = "GitHub returned HTTP #{response.code}" if detail.empty?
          { ok: false, error_code: "provider_error", provider_error: detail.truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
