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

  # Outcomes of #verify_for_login.
  VERIFIED = :verified
  INVALID = :invalid

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
    stamp = enrollment.is_a?(Hash) ? enrollment["created_at"] : nil
    return true if stamp.blank?

    Time.parse(stamp.to_s) < ENROLLMENT_TTL.ago
  rescue ArgumentError
    true
  end

  # The one place a secret becomes the account's, and it costs a code that has
  # already been checked against it. Backup codes are minted in the same
  # transaction: a second factor with no way back in is a support ticket, and a
  # half-activated account is worse.
  def self.activate!(user, secret)
    user.transaction do
      user.update!(otp_secret: secret, otp_enabled: true, otp_last_step: nil,
        otp_failed_attempts: 0, otp_locked_until: nil)
      RecoveryCode.generate!(user)
    end
  end

  # Off means gone: the secret and every code issued against it. Without the
  # factor those strings would be a second way in rather than a way back.
  def self.disable!(user)
    user.transaction do
      user.update!(otp_enabled: false, otp_secret: nil, otp_last_step: nil,
        otp_failed_attempts: 0, otp_locked_until: nil)
      user.recovery_codes.delete_all
    end
  end

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

  # Sign-in match, with the replay guard: ROTP's `after:` refuses any step at or
  # before the one last accepted, so a code cannot be spent twice even inside
  # its 90-second validity window. The winning step is recorded for next time.
  def verify_for_login(code)
    ts = match(code, after: user.otp_last_step)
    return INVALID if ts.nil?

    user.remember_totp_step!(ts / STEP_SECONDS)
    VERIFIED
  end

  def provisioning_uri
    totp.provisioning_uri(user.email)
  end

  def qr_svg(module_size: 4)
    qr_code = RQRCode::QRCode.new(provisioning_uri)
    dimension = qr_code.modules.count * module_size
    path = qr_code.as_svg(module_size: module_size, standalone: false, use_path: true)
    label = ERB::Util.html_escape(user.email)

    "<svg viewBox=\"0 0 #{dimension} #{dimension}\" width=\"#{dimension}\" height=\"#{dimension}\" " \
      "xmlns=\"http://www.w3.org/2000/svg\" shape-rendering=\"crispEdges\" role=\"img\" " \
      "aria-label=\"QR code for #{label}\">#{path}</svg>".html_safe
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
