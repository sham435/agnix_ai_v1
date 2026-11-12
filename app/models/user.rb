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
#  otp_secret             :string
#  otp_enabled            :boolean          default(FALSE), not null
#  otp_last_step          :integer
#  otp_failed_attempts    :integer          default(0), not null
#  otp_locked_until       :datetime
#  phone                  :string
#  phone_verified_at      :datetime
#  sessions_invalid_before: :datetime
#
class User < ApplicationRecord
  has_secure_password
  has_secure_token :remember_token

  # Encrypted with the secret_key_base-derived keys configured for
  # ToolIntegration#credentials; never queried by value.
  encrypts :otp_secret

  # Associations.
  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships
  has_many :owned_organizations, class_name: "Organization", foreign_key: :owner_id, dependent: :destroy

  has_many :conversations, dependent: :destroy
  has_many :memories, dependent: :destroy

  has_many :assets, dependent: :destroy
  has_many :library_items, dependent: :destroy
  has_many :scheduled_tasks, dependent: :destroy
  # Security-panel rows. Backup codes and verification codes hold nothing but
  # digests, and auth sessions nothing but token digests, so they can go with
  # the account in one bulk delete.
  has_many :recovery_codes, dependent: :destroy
  has_many :auth_sessions, dependent: :delete_all
  has_many :phone_verifications, dependent: :delete_all
  # Generation rows only reference assets (bytes stay in the assets tree), so
  # they can be bulk-deleted with the user.
  has_many :image_generations, dependent: :delete_all

  enum :role, { user: "user", admin: "admin" }, default: :user

  normalizes :email, with: ->(e) { e.strip.downcase }
  normalizes :whatsapp_phone, with: ->(p) { p&.gsub(/\D/, "") }
  # Only ever written from a verified number, but normalized anyway so a
  # hand-edited row cannot store something the SMS driver would not recognize.
  normalizes :phone, with: ->(p) { PhoneVerification.normalize(p) }

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password_digest, presence: true
  validates :phone, uniqueness: true, allow_nil: true

  store_accessor :settings, :theme, :ui_theme, :locale, :notifications_enabled

  # Phase 1 theme resolution order for the no-FOUC head script:
  #   explicit ui_theme (dark|light) > legacy theme > nil (client decides).
  # Returns "dark" / "light" / nil — nil means "let the browser hint decide".
  def resolved_ui_theme
    val = ui_theme.presence || theme.presence
    %w[dark light].include?(val.to_s) ? val.to_s : nil
  end

  generates_token_for :password_reset, expires_in: 15.minutes

  # Scopes.
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :recent, -> { order(created_at: :desc).limit(20) }

  # Methods.
  def owner?(organization)
    owned_organizations.include?(organization)
  end

  # An "owner" membership carries admin rights too — without it, the person who
  # created an organization could not edit it or invite anyone into it.
  def admin?(organization = nil)
    return true if role == "admin"
    return false unless organization

    %w[admin owner].include?(memberships.find_by(organization: organization)&.role)
  end

  def active_organization
    @active_organization ||= organizations.first
  end

  def two_factor
    @two_factor ||= TwoFactor.new(self)
  end

  # Guesses allowed against the second factor before the account pauses itself.
  # Counted on the row, not in the session: going back to the password page
  # must not hand a guesser a fresh budget.
  MAX_SECOND_FACTOR_ATTEMPTS = 5
  SECOND_FACTOR_LOCKOUT = 15.minutes

  # ── security-panel state ───────────────────────────────────────────────
  def second_factor_enabled?
    otp_enabled? && otp_secret.present?
  end

  def two_factor_locked?
    otp_locked_until.present? && otp_locked_until > Time.current
  end

  def two_factor_lock_minutes_left
    return 0 unless two_factor_locked?

    ((otp_locked_until - Time.current) / 60).ceil
  end

  def recovery_codes_remaining
    recovery_codes.unused.count
  end

  def phone_verified?
    phone_verified_at.present?
  end

  # Records a failed second-factor guess and pauses the account once the
  # budget is spent. The row lock keeps two concurrent guesses from both
  # seeing "one attempt left".
  def note_second_factor_failure!
    with_lock do
      unless two_factor_locked?
        self.otp_failed_attempts += 1
        self.otp_locked_until = SECOND_FACTOR_LOCKOUT.from_now if otp_failed_attempts >= MAX_SECOND_FACTOR_ATTEMPTS
        save!
      end
    end
    two_factor_locked?
  end

  def clear_second_factor_failures!
    update!(otp_failed_attempts: 0, otp_locked_until: nil)
  end

  # The 30-second step of the last code accepted. Anything at or before it is a
  # replay, which stops a code that was already used from working a second time
  # inside its validity window.
  def remember_totp_step!(step)
    update!(otp_last_step: step) if step.to_i.positive?
  end

  # Count shown as the /scheduled sidebar badge (Phase 2). Kept in the model so
  # the app-shell layout never issues its own query.
  def active_scheduled_task_count
    scheduled_tasks.active_scheduled.count
  end

  # Count shown as the /images sidebar badge (Phase 3): successful generations
  # from the past week. Same rule as above — the layout never queries directly.
  def recent_image_generation_count
    image_generations.succeeded.where(created_at: 7.days.ago..).count
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
