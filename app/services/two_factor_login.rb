# The second factor, decided server-side from one input box.
#
# A six-digit guess is a time-based code; anything else is read as a backup
# code. Both go through the same failure counter, because both are guesses at
# the same protection. Phone OTP codes never reach this class — SMS proves
# ownership of a number, not identity at sign-in (see PhoneVerification).
class TwoFactorLogin
  Result = Struct.new(:status, :recovery_codes_left, :minutes_left, keyword_init: true)

  TOTP_LENGTH = 6

  def self.verify(user:, code:)
    new(user).verify(code)
  end

  def initialize(user)
    @user = user
  end

  def verify(code)
    @user.with_lock do
      next Result.new(status: :disabled, recovery_codes_left: 0, minutes_left: 0) unless @user.second_factor_enabled?
      next locked if @user.two_factor_locked?

      value = code.to_s.delete(" -").upcase
      next invalid if value.blank?

      if totp_shape?(value)
        @user.two_factor.verify_for_login(value) == TwoFactor::VERIFIED ? success(:verified) : invalid
      else
        RecoveryCode.consume!(@user, value) ? success(:recovery_used) : invalid
      end
    end
  end

  private

  # Six bare digits are an authenticator code; recovery codes are longer.
  def totp_shape?(value)
    value.match?(/\A\d{#{TOTP_LENGTH}}\z/)
  end

  def success(status)
    @user.clear_second_factor_failures!
    Result.new(status: status, recovery_codes_left: @user.recovery_codes_remaining, minutes_left: 0)
  end

  def invalid
    locked = @user.note_second_factor_failure!
    Result.new(status: locked ? :locked : :invalid, recovery_codes_left: @user.recovery_codes_remaining,
      minutes_left: @user.two_factor_lock_minutes_left)
  end

  def locked
    Result.new(status: :locked, recovery_codes_left: @user.recovery_codes_remaining,
      minutes_left: @user.two_factor_lock_minutes_left)
  end
end
