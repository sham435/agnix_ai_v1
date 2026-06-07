# == Schema Information
#
# Table name: users
#
#  id                     :uuid             not null, primary key
#  email                  :string           not null
#  password_digest        :string           not null
#  name                   :string
#  role                   :string           default("user"), not null
#  stripe_customer_id     :string
#  whatsapp_phone         :string
#  settings               :jsonb            default({}), not null
#  remember_token         :string
#  confirmed_at           :datetime
#  last_login_at          :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
class User < ApplicationRecord
  has_secure_password
  has_secure_token :remember_token

  # Associations.
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :owned_organizations, class_name: "Organization", foreign_key: :owner_id, dependent: :destroy

  has_many :conversations, dependent: :destroy
  has_many :memories, dependent: :destroy

  enum :role, { user: "user", admin: "admin" }, default: :user

  normalizes :email, with: ->(e) { e.strip.downcase }
  normalizes :whatsapp_phone, with: ->(p) { p&.gsub(/\D/, "") }

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password_digest, presence: true

  store_accessor :settings, :theme, :locale, :notifications_enabled

  generates_token_for :password_reset, expires_in: 15.minutes

  # Scopes.
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :recent, -> { order(created_at: :desc).limit(20) }

  # Methods.
  def owner?(organization)
    owned_organizations.include?(organization)
  end

  def admin?(organization = nil)
    return true if role == "admin"
    return false unless organization
    memberships.find_by(organization: organization)&.admin?
  end

  def active_organization
    @active_organization ||= organizations.first
  end

  def avatar_url
    return gravatar_url if settings["avatar"] == "gravatar"
    settings["avatar_url"]
  end

  private

  def gravatar_url
    hash = Digest::MD5.hexdigest(email)
    "https://www.gravatar.com/avatar/#{hash}?d=identicon&s=200"
  end
end
