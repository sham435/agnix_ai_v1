# Phone-number verification: the policy layer between the panel/API and
# SmsService. Normalizes the number, spends the cooldown and the hourly
# sending windows, and only writes a code row when something can actually
# deliver it. The code itself is a property of the row (see PhoneVerification),
# and the plaintext leaves this class only for the local dev driver.
class PhoneVerifier
  Result = Struct.new(:status, :message, :code, :retry_in, keyword_init: true)

  UNCONFIGURED = SmsService::NOT_CONFIGURED

  def initialize(user, ip: nil)
    @user = user
    @ip = ip
  end

  def self.request(user, phone:, ip: nil)
    new(user, ip: ip).request(phone)
  end

  def self.confirm(user, code:, ip: nil)
    new(user, ip: ip).confirm(code)
  end

  def request(raw_phone)
    phone = PhoneVerification.normalize(raw_phone)
    return failure(:invalid_number, "Enter a mobile number in international format, like +94771234567.") if phone.nil?
    return failure(:limited, "Too many codes have been sent from here recently. Try again later.") if over_window?(phone)

    pending = PhoneVerification.current_for(@user)
    if pending&.resend_blocked?
      return failure(:cooldown, "That code is still valid. Wait before asking for another.",
        retry_in: (pending.resend_allowed_at - Time.current).ceil.clamp(1, PhoneVerification::RESEND_COOLDOWN.to_i))
    end

    return failure(:unconfigured, UNCONFIGURED) if SmsService.driver == "none"

    row = PhoneVerification.issue!(@user, phone: phone, channel: SmsService.driver, ip: @ip)
    delivered = SmsService.deliver(phone: phone, code: row.code)
    unless delivered[:ok]
      row.destroy
      return failure(:undelivered, delivered[:error] || "The code could not be sent.")
    end

    Result.new(status: :sent, code: SmsService.reveals_code? ? row.code : nil,
      message: "We sent a #{PhoneVerification::CODE_LENGTH}-digit code to #{phone}.",
      retry_in: PhoneVerification::RESEND_COOLDOWN.to_i)
  end

  def confirm(input)
    row = PhoneVerification.current_for(@user)
    return failure(:no_code, "Ask for a code first.") if row.nil?

    case row.verify(input)
    when PhoneVerification::VERIFIED
      Result.new(status: :verified, message: "#{@user.phone} is verified.")
    when PhoneVerification::EXPIRED
      failure(:expired, "That code expired. Request a new one.")
    when PhoneVerification::EXHAUSTED
      failure(:exhausted, "Too many wrong attempts for that code. Request a new one.")
    when PhoneVerification::ALREADY_CONSUMED
      failure(:consumed, "That code was already used. Request a new one.")
    else
      left = [ PhoneVerification::MAX_ATTEMPTS - row.attempts, 0 ].max
      failure(:invalid, "That code is not right. #{left} #{left == 1 ? "try" : "tries"} left.")
    end
  end

  private

  def over_window?(phone)
    PhoneVerification.sent_by_user?(@user) || PhoneVerification.sent_to_phone?(phone) ||
      PhoneVerification.sent_from_ip?(@ip)
  end

  def failure(status, message, retry_in: nil)
    Result.new(status: status, message: message, retry_in: retry_in)
  end
end
