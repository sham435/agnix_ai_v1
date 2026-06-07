# == Schema Information
#
# Table name: agents
#
#  id              :uuid             not null, primary key
#  organization_id :uuid             not null
#  name            :string           not null
#  slug            :string           not null
#  description     :text
#  system_prompt   :text
#  model           :string           default("claude-sonnet-4-6"), not null
#  provider        :string           default("anthropic"), not null
#  tools           :jsonb            default([]), not null
#  config          :jsonb            default({}), not null
#  is_active       :boolean          default(TRUE), not null
#  runs_count      :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
class Agent < ApplicationRecord
  MODELS = {
    anthropic: %w[claude-opus-4-8 claude-sonnet-4-6 claude-haiku-4-5-20251001],
    openai: %w[gpt-4o gpt-4o-mini o1 o3-mini],
    ollama: %w[llama3.1 mistral codellama],
    opencode: %w[deepseek-v4-flash-free big-pickle nemotron-3-super-free minimax-m3-free mimo-v2.5-free]
  }.freeze

  belongs_to :organization, touch: true

  has_many :conversations, dependent: :destroy
  has_many :runs, dependent: :destroy, counter_cache: true
  has_many :memories, dependent: :nullify
  has_many :projects, dependent: :destroy

  enum :provider, { anthropic: "anthropic", openai: "openai", google: "google", opencode: "opencode", ollama: "ollama" }

  validates :name, :slug, :model, presence: true
  validates :slug, uniqueness: { scope: :organization_id }

  normalizes :slug, with: ->(s) { s.parameterize }
  normalizes :model, with: ->(m) { m.strip }

  store_accessor :config, :temperature, :max_tokens, :top_p
  store_accessor :tools, prefix: true

  scope :active, -> { where(is_active: true) }

  # Methods.
  def enabled_tools
    tools.reject { |t| t.is_a?(Hash) && t["enabled"] == false }
  end

  def llm_client
    Llm::Client.new(
      provider: provider,
      model: model,
      temperature: config.fetch("temperature", 0.7),
      max_tokens: config.fetch("max_tokens", 4096),
      api_key: api_key
    )
  end

  def api_key
    credential = organization.tool_integrations.find_by(provider: provider, is_active: true)
    credential&.decrypted_credentials&.fetch("api_key", nil) ||
      Rails.application.credentials.dig(provider.to_sym, :api_key) ||
      ENV.fetch("#{provider.upcase}_API_KEY", "")
  end

  def duplicate(user)
    dup.tap do |copy|
      copy.name = "#{name} (Copy)"
      copy.slug = nil
      copy.organization = user.active_organization
    end
  end
end
