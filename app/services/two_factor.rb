# Time-based one-time codes (RFC 6238) for the optional second sign-in factor.
#
# Stateless by design: an in-flight enrollment passes its own secret in, so a
# secret the user never confirmed is never written to their row.
class TwoFactor
  ISSUER = "Shams AI".freeze
  SECRET_BYTES = 20
  # Authenticator clocks are rarely exact; ROTP widens this to whole 30s steps,
  # so 30 means "the previous and the next code also count".
  DRIFT_SECONDS = 30
  STEP_SECONDS = 30
  # An enrollment that is never confirmed is simply garbage after this long.
  ENROLLMENT_TTL = 15.minutes

  VERIFIED = :verified
  INVALID = :invalid
  ERRORS = {
    invalid: "That code didn't work. Check your app and try again.",
    expired: "That setup request expired. Start again.",
    locked: "Too many incorrect codes. Try again after the lock expires.",
    already_enabled: "Two-factor is already on. Turn it off before setting it up again.",
    invalid_password: "Wrong password. Nothing was changed.",
    disabled: "Set up two-factor first — backup codes only exist to replace an authenticator."
  }.freeze
  Result = Struct.new(:status, :recovery_codes, keyword_init: true) do
    def error = ERRORS.fetch(status)
  end

  def self.generate_secret
    ROTP::Base32.random(SECRET_BYTES)
  end

  # The enrollment secret is parked in the visitor's own session with the
  # moment it was minted, so an abandoned setup cannot be confirmed tomorrow.
  # String keys: the cookie session store in production serializes to JSON and
  # would hand back a different shape than the cache store does in development.
  def self.new_enrollment
    { "secret" => generate_secret, "created_at" => Time.current.iso8601 }
  end

  def self.enrollment_expired?(enrollment)
    return true unless enrollment.is_a?(Hash) && enrollment["secret"].present?

    stamp = Time.iso8601(enrollment.fetch("created_at").to_s)
    stamp <= ENROLLMENT_TTL.ago || stamp > Time.current
  rescue ArgumentError, KeyError
    true
  end

  def self.confirm_enrollment(user:, enrollment:, code:)
    result = new(user).confirm_enrollment(enrollment: enrollment, code: code)
    Rails.logger.info(event: "two_factor.enrolled", user_id: user.id) if result.status == VERIFIED
    result
  end

  # The one place a secret becomes the account's, and it costs a code that has
  # already been checked against it. Backup codes are minted in the same
  # transaction: a second factor with no way back in is a support ticket, and a
  # half-activated account is worse.
  def self.activate!(user, secret, step: nil)
    user.with_lock do
      user.update!(otp_secret: secret, otp_enabled: true, otp_last_step: step,
        otp_failed_attempts: 0, otp_locked_until: nil)
      RecoveryCode.generate!(user)
    end
  end

  # Off means gone: the secret and every code issued against it. Without the
  # factor those strings would be a second way in rather than a way back.
  def self.disable!(user)
    user.with_lock do
      user.update!(otp_enabled: false, otp_secret: nil, otp_last_step: nil,
        otp_failed_attempts: 0, otp_locked_until: nil)
      user.recovery_codes.delete_all
    end
  end

  def self.disable(user:, password:, code:)
    result = authorize_change(user: user, password: password, code: code) do
      disable!(user)
      Result.new(status: VERIFIED)
    end
    Rails.logger.info(event: "two_factor.disabled", user_id: user.id) if result.status == VERIFIED
    result
  end

  def self.regenerate_recovery_codes(user:, password:, code:)
    result = authorize_change(user: user, password: password, code: code) do
      Result.new(status: VERIFIED, recovery_codes: RecoveryCode.generate!(user))
    end
    if result.status == VERIFIED
      Rails.logger.info(event: "two_factor.recovery_codes_regenerated", user_id: user.id)
    end
    result
  end

  def self.authorize_change(user:, password:, code:)
    user.with_lock do
      next Result.new(status: :disabled) unless user.second_factor_enabled?
      next Result.new(status: :invalid_password) unless user.authenticate(password.to_s)

      proof = TwoFactorLogin.verify(user: user, code: code)
      next Result.new(status: proof.status) unless proof.status.in?([ :verified, :recovery_used ])

      yield
    end
  end
  private_class_method :authorize_change

  attr_reader :user, :secret

  def initialize(user, secret: nil)
    @user = user
    @secret = secret.presence || user.otp_secret
  end

  # Raw match against the secret this object holds. Enrollment uses it, because
  # there the code is proving the pending key works, not proving a sign-in.
  def valid?(code)
    !match(code).nil?
  end

  def confirm_enrollment(enrollment:, code:)
    user.with_lock do
      next Result.new(status: :already_enabled) if user.otp_enabled?
      next Result.new(status: :expired) if self.class.enrollment_expired?(enrollment)
      next Result.new(status: :locked) if user.two_factor_locked?

      @secret = enrollment.fetch("secret")
      timestamp = match(code)
      unless timestamp
        status = user.note_second_factor_failure! ? :locked : INVALID
        next Result.new(status: status)
      end

      codes = self.class.activate!(user, secret, step: timestamp / STEP_SECONDS)
      Result.new(status: VERIFIED, recovery_codes: codes)
    end
  end

  # Match only the current persisted secret and counter, never a cached key.
  def verify_for_login(code)
    user.with_lock do
      next INVALID unless user.second_factor_enabled?

      @secret = user.otp_secret
      timestamp = match(code, after: user.otp_last_step)
      next INVALID unless timestamp

      user.remember_totp_step!(timestamp / STEP_SECONDS)
      VERIFIED
    end
  end

  def provisioning_uri
    totp.provisioning_uri(user.email)
  end

  def qr_svg(module_size: 4)
    qr_code = RQRCode::QRCode.new(provisioning_uri)
    modules = qr_code.modules.count + 8
    dimension = modules * module_size
    path = qr_code.as_svg(module_size: 1, standalone: false, use_path: true)
    label = ERB::Util.html_escape(user.email)

    "<svg viewBox=\"0 0 #{modules} #{modules}\" width=\"#{dimension}\" height=\"#{dimension}\" " \
      "xmlns=\"http://www.w3.org/2000/svg\" shape-rendering=\"crispEdges\" role=\"img\" " \
      "style=\"max-width:100%;height:auto\" aria-label=\"Scan to add #{label} to your authenticator\">" \
      "<rect width=\"#{modules}\" height=\"#{modules}\" fill=\"#fff\"/>" \
      "<g transform=\"translate(4 4)\">#{path}</g></svg>".html_safe
  end

  private

  def totp
    ROTP::TOTP.new(secret, issuer: ISSUER)
  end

  # The timestamp of the step that matched, or nil. `after` is a step number,
  # which ROTP turns into "ignore every step up to and including this one".
  def match(code, after: nil)
    return nil if secret.blank?

    normalized = code.to_s.delete(" -")
    return nil unless normalized.match?(/\A\d{6}\z/)

    floor = after.present? ? after.to_i * STEP_SECONDS : nil
    totp.verify(normalized, drift_behind: DRIFT_SECONDS, drift_ahead: DRIFT_SECONDS, after: floor)
  end
end
