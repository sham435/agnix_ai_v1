# Phone-number verification, drawn inside the account panel.
#
# Separate mechanism on purpose: this proves someone controls a number, which
# is a different claim from the authenticator code, and an SMS code is never
# accepted at sign-in. Delivery itself lives in SmsService, and this app has no
# SMS credentials yet — when the driver is not configured, saying so is the
# only honest answer, so the section never pretends a code was sent.
class Account::PhonesController < ApplicationController
  include AccountPanelResponses

  before_action :authenticate_user!

  def request_code
    result = PhoneVerifier.request(current_user, phone: params[:phone], ip: request.remote_ip)
    @phone_result = result

    if result.status == :sent
      # The dev driver has no transport, so the code is shown to the person who
      # just asked for it — never logged, never sent to another session.
      @dev_code = result.code
      render_panel(section: "phone", notice: result.message)
    else
      render_panel(section: "phone", status: status_for(result.status), alert: result.message)
    end
  end

  def confirm
    result = PhoneVerifier.confirm(current_user, code: params[:code], ip: request.remote_ip)
    @phone_result = result

    if result.status == :verified
      render_panel(section: "security", notice: result.message)
    else
      render_panel(section: "phone", status: status_for(result.status), alert: result.message)
    end
  end

  private

  # Cooldowns and rate limits are real refusals, so they get the HTTP status
  # that says so instead of a generic 422.
  def status_for(status)
    case status
    when :cooldown, :limited then :too_many_requests
    else :unprocessable_entity
    end
  end
end
