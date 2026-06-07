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
  PROVIDERS = %w[stripe whatsapp google github postmark resend slack notion].freeze

  belongs_to :organization

  encrypts :credentials

  validates :name, :provider, presence: true
  validates :provider, uniqueness: { scope: :organization_id }

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

  # Provider-specific helpers.
  def stripe_client
    return nil unless provider == "stripe"
    Stripe::StripeClient.new(api_key)
  end

  def whatsapp_phone_number_id
    return nil unless provider == "whatsapp"
    config["phone_number_id"]
  end
end
