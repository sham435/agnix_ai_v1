# == Schema Information
#
# Table name: tool_integrations
#
#  id              :uuid             not null, primary key
#  organization_id :uuid             not null
#  provider        :string           not null
#  name            :string           not null
#  credentials     :jsonb            not null
#  config          :jsonb            default({}), not null
#  is_active       :boolean          default(TRUE), not null
#  last_used_at    :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class ToolIntegration < ApplicationRecord
  PROVIDERS = %w[stripe whatsapp google github postmark resend slack notion webhook web_search figma].freeze

  def self.connection_for(organization, provider)
    return nil unless organization

    organization.tool_integrations.active.find_by(provider: provider)
  end

  def self.connection_disabled?(organization, provider)
    return false unless organization

    organization.tool_integrations.exists?(provider: provider, is_active: false)
  end

  def self.whatsapp_integration_for(phone_number_id)
    return nil if phone_number_id.blank?

    matches = active.where(provider: "whatsapp")
      .where("config->>'phone_number_id' = ?", phone_number_id.to_s)
      .limit(2).to_a
    matches.first if matches.length == 1
  end

  def self.whatsapp_organization_for(phone_number_id)
    whatsapp_integration_for(phone_number_id)&.organization
  end

  def self.authorized_organization_for(user, context = {})
    return nil unless user.is_a?(User)

    organization = if context[:agent_id].present?
      Agent.find_by(id: context[:agent_id])&.organization
    else
      context[:organization] || user.active_organization
    end
    return nil unless organization && (user.owner?(organization) || user.organizations.exists?(id: organization.id))

    organization
  end

  belongs_to :organization

  encrypts :credentials

  validates :name, :provider, presence: true
  validates :provider, uniqueness: { scope: :organization_id }

  # Both jsonb columns are NOT NULL, and an encrypted attribute (nor a raw
  # pg jsonb default, which deserializes to the STRING "{}" before any DB
  # round trip) leaves an in-memory nil/"" when the params omit them — the
  # credentials-less Custom Webhook connect would then crash with
  # ActiveRecord::NotNullViolation. Coerce to real hashes pre-validation.
  before_validation :ensure_json_defaults

  normalizes :provider, with: ->(p) { p.strip.downcase }

  store_accessor :config, :webhook_url, :timeout

  scope :active, -> { where(is_active: true) }

  # Methods.
  def decrypted_credentials
    # Rails 7.1+ encrypts jsonb columns transparently.
    # If using older patterns, decrypt manually here.
    credentials
  rescue
    credentials
  end

  def api_key
    decrypted_credentials.is_a?(Hash) ? decrypted_credentials["api_key"] : nil
  end

  def webhook_secret
    decrypted_credentials.is_a?(Hash) ? decrypted_credentials["webhook_secret"] : nil
  end

  def touch_usage
    update!(last_used_at: Time.current)
  end

  # Marketplace on/off switch (Phase 4). The flip lives here so the toggle
  # route stays a thin dispatcher; disabled rows leave the active scope and
  # their tools stop surfacing to agents.
  def toggle_active!
    update!(is_active: !is_active?)
  end

  # Provider-specific helpers.
  def stripe_client
    return nil unless provider == "stripe"
    Stripe::StripeClient.new(api_key)
  end

  def whatsapp_phone_number_id
    return nil unless provider == "whatsapp"
    config["phone_number_id"]
  end

  private

  # nil (encrypted attr without input) or the STRING "{}" (raw pg jsonb
  # default seen before any DB round trip) both crash the insert or later
  # .merge calls. Anything not already a Hash becomes a real empty Hash.
  def ensure_json_defaults
    self.credentials = {} unless credentials.is_a?(Hash)
    self.config = {} unless config.is_a?(Hash)
  end
end
