# frozen_string_literal: true

#
# Display helpers for the integrations surfaces. Their whole job is to explain
# where a provider credential will actually be read from WITHOUT rendering the
# secret: Agent#api_key resolves organization integration -> Rails credentials
# -> ENV -> provider default, so a card that only says "Inactive" is misleading
# when a perfectly usable environment key is in place.
module IntegrationsHelper
  # Last-4 fingerprint of a stored credential ("••••abcd"), or nil when the row
  # holds no key. Never the full value.
  def key_fingerprint(integration)
    key = integration&.api_key.to_s
    return nil if key.blank?

    "••••#{key.last(4)}"
  end

  # Where runs for this provider will pull their credential from, mirroring
  # Agent#api_key's precedence order.
  def key_source_label(provider, integration)
    if integration&.is_active? && integration.api_key.present?
      "Organization key"
    elsif integration && integration.api_key.present?
      "Organization key (paused)"
    elsif Rails.application.credentials.dig(provider.to_sym, :api_key).present?
      "Rails credentials"
    elsif ENV["#{provider.upcase}_API_KEY"].present?
      "Environment key"
    elsif provider == "bonsai"
      "Local server"
    else
      "No key configured"
    end
  end
end
