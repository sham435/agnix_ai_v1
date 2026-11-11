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

  def self.generate_secret
    ROTP::Base32.random(SECRET_BYTES)
  end

  attr_reader :user, :secret

  def initialize(user, secret: nil)
    @user = user
    @secret = secret.presence || user.otp_secret
  end

  def valid?(code)
    return false if secret.blank?

    normalized = code.to_s.delete(" -")
    return false if normalized.blank?

    !totp.verify(normalized, drift_behind: DRIFT_SECONDS, drift_ahead: DRIFT_SECONDS).nil?
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
end
