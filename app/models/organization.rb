# == Schema Information
#
# Table name: organizations
#
#  id         :uuid             not null, primary key
#  name       :string           not null
#  slug       :string           not null
#  owner_id   :uuid             not null
#  plan       :string           default("free"), not null
#  settings   :jsonb            default({}), not null
#  conversations_count :integer default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Organization < ApplicationRecord
  belongs_to :owner, class_name: "User"

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  has_many :agents, dependent: :destroy
  has_many :conversations, through: :agents
  has_many :tool_integrations, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :usage_events, dependent: :destroy

  enum :plan, { free: "free", pro: "pro", enterprise: "enterprise" }, default: :free

  validates :name, :slug, presence: true
  validates :slug, uniqueness: true

  store_accessor :settings, :brand_color, :logo_url

  normalizes :slug, with: ->(s) { s.parameterize }

  # Scopes.
  scope :active, -> { where.not(plan: "suspended") }

  # Methods.
  def add_user(user, role: "member")
    memberships.create!(user: user, role: role)
  end

  def remove_user(user)
    memberships.find_by(user: user)&.destroy
  end

  def user_count
    memberships.count
  end

  def active_agents_count
    agents.where(is_active: true).count
  end
end
