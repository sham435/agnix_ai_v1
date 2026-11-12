# Phone verification over the API. Deliberately its own thing: this proves
# someone holds a number, which is what registration and Coffee Key purchases
# need, and a code from here is never accepted at sign-in. Delivery follows
# whatever SmsService is configured for — with no gateway the response says so
# instead of pretending a text went out.
class Api::V1::PhoneController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  def create
    render_phone PhoneVerifier.request(current_user, phone: params[:phone], ip: request.remote_ip)
  end

  def confirm
    render_phone PhoneVerifier.confirm(current_user, code: params[:code], ip: request.remote_ip)
  end

  private

  def render_phone(result)
    payload = { status: result.status, message: result.message }
    payload[:retry_in] = result.retry_in if result.retry_in
    # Only ever set by the local development driver, for the session that just
    # asked; a real gateway leaves it nil and nothing about it is sent.
    payload[:code] = result.code if result.code

    if %i[sent verified].include?(result.status)
      render json: security_snapshot.merge(payload), status: :ok
    else
      render json: payload, status: status_for(result.status)
    end
  end

  # Cooldowns and rate limits are real refusals with a "not yet" attached, so
  # they answer 429 with the wait in the body; the rest are the request being
  # wrong. Same mapping the panel's controller uses.
  def status_for(status)
    case status
    when :cooldown, :limited then :too_many_requests
    else :unprocessable_entity
    end
  end
end
