# frozen_string_literal: true

require "net/http"

module Integrations
  # GET only. The token must have Figma file_content:read permission.
  class FigmaGetFile
    def self.call(integration:, arguments:, context: {})
      return { ok: false, error_code: "integration_inactive" } unless integration.is_active?
      if context.key?(:user) || context.key?(:user_id)
        user = Agents::ToolRegistry::ToolContext.user_for(context)
        organization = ToolIntegration.authorized_organization_for(user, context)
        return { ok: false, error_code: "not_authorized" } unless organization&.id == integration.organization_id
      end
      key = arguments["file_key"]
      depth = arguments.fetch("depth", 2)
      unless key.is_a?(String) && key.match?(/\A[a-zA-Z0-9]{1,128}\z/) && depth.is_a?(Integer) && (1..5).cover?(depth)
        return { ok: false, error_code: "invalid_request" }
      end
      token = integration.api_key
      return { ok: false, error_code: "missing_credentials" } if token.blank?
      return { ok: false, error_code: "invalid_credentials" } unless token.is_a?(String) && token.match?(/\A[^\s\x00-\x1f\x7f]{1,512}\z/)

      uri = URI("https://api.figma.com/v1/files/#{key}?depth=#{depth}")
      request = Net::HTTP::Get.new(uri)
      request["X-Figma-Token"] = token
      parsed = BoundedJsonRequest.call(uri: uri, request: request)
      return { ok: false, error_code: "provider_error" } unless parsed["document"].is_a?(Hash)

      { ok: true, provider: "figma", file_key: key, result: parsed.slice("name", "lastModified", "version", "document") }
    rescue StandardError
      { ok: false, error_code: "provider_error" }
    end
  end
end
