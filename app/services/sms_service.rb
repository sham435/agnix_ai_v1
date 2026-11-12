# Transport for phone-verification codes.
#
# There is no SMS gem in this app and no provider credentials, so this deliberately
# ships three drivers and activates none of them by surprise:
#
#   "dev"      — no transport at all. The code is handed back to the caller so a
#                local panel can show it. Never available outside a local env.
#   "whatsapp" — the WhatsApp Cloud API integration this app already has.
#   "none"     — verification is off and every request says so.
#
# A real SMS gateway is a fourth driver here plus `SHAMS_SMS_DRIVER=sms`; nothing
# else in the app knows how a code reaches a phone.
class SmsService
  TEXT = "Your Shams AI verification code is %s. It expires in %d minutes.".freeze
  NOT_CONFIGURED = "No SMS gateway is configured on this server yet.".freeze

  class << self
    def driver
      name = ENV["SHAMS_SMS_DRIVER"].presence || (Rails.env.local? ? "dev" : "none")
      name == "dev" && !Rails.env.local? ? "none" : name
    end

    # Whether the caller may show the code itself — the dev driver's only
    # transport. Guarded twice: driver name and environment.
    def reveals_code?
      driver == "dev" && Rails.env.local?
    end

    def deliver(phone:, code:)
      case driver
      when "dev"      then { ok: true, channel: "dev" }
      when "whatsapp" then via_whatsapp(phone, code)
      else { ok: false, channel: "none", error: NOT_CONFIGURED }
      end
    end

    private

    def via_whatsapp(phone, code)
      result = WhatsappService.send_message(phone, format(TEXT, code, (PhoneVerification::TTL / 60).to_i))
      error = result.is_a?(Hash) ? (result[:error] || result["error"]) : nil
      if error
        { ok: false, channel: "whatsapp", error: "WhatsApp could not send the code: #{error}" }
      else
        { ok: true, channel: "whatsapp" }
      end
    rescue StandardError => e
      # The message text is the code — never let an exception carry it out.
      Rails.logger.warn("SmsService: whatsapp delivery failed (#{e.class})")
      { ok: false, channel: "whatsapp", error: "WhatsApp could not send the code right now." }
    end
  end
end
