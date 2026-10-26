# frozen_string_literal: true

require "httparty"
require "cgi"

module Integrations
  module Github
    # Real GitHub REST call with the org's PAT (credentials api_key).
    # The app never stores GitHub OAuth tokens (OauthCallbacksController
    # only logs users in), so a pasted token is the supported path.
    class CreateIssue
      extend Integrations::HttpSupport

      API_BASE = "https://api.github.com"
      VERSION_HEADERS = {
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28"
      }.freeze

      def self.call(integration:, arguments:, context: {})
        token = integration.api_key
        return { ok: false, error_code: "missing_credentials" } if token.blank?

        owner = arguments["owner"].to_s.strip
        repo = arguments["repo"].to_s.strip
        title = arguments["title"].to_s.strip
        errors = []
        errors << "owner is required" if owner.empty?
        errors << "repo is required" if repo.empty?
        errors << "title is required" if title.empty?
        return { ok: false, error_code: "invalid_request", errors: errors } if errors.any?

        payload = { title: title }
        payload[:body] = arguments["body"] if arguments["body"].present?
        payload[:labels] = arguments["labels"] if arguments["labels"].is_a?(Array) && arguments["labels"].any?

        response = HTTParty.post(
          "#{API_BASE}/repos/#{CGI.escape(owner)}/#{CGI.escape(repo)}/issues",
          headers: bearer_headers(token, VERSION_HEADERS),
          body: payload.to_json,
          timeout: timeout_for(integration)
        )
        parsed = parse_json(response)

        if http_ok?(response.code) && parsed["number"].present?
          {
            ok: true, provider: "github", issue_number: parsed["number"],
            html_url: parsed["html_url"], title: parsed["title"]
          }
        else
          detail = parsed["message"].to_s.presence || "GitHub returned HTTP #{response.code}"
          { ok: false, error_code: "provider_error", provider_error: detail.truncate(200) }
        end
      rescue StandardError => e
        { ok: false, error_code: "request_failed", detail: e.message.to_s.truncate(200) }
      end
    end
  end
end
