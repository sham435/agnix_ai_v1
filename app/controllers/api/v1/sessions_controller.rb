class Api::V1::SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create

  def create
    user = User.find_by(email: params[:email].to_s.downcase)

    unless user&.authenticate(params[:password])
      return render json: { error: "Invalid email or password." }, status: :unauthorized
    end

    return sign_in(user) unless user.second_factor_enabled?

    if params[:code].blank?
      request_two_factor(user)
      return render_two_factor_required(false)
    end

    unless pending_two_factor_user&.id == user.id
      sign_out_current_request
      return render_two_factor_required(false)
    end

    result = TwoFactorLogin.verify(user: user, code: params[:code])

    case result.status
    when :verified then sign_in(user, mfa_verified: true)
    when :recovery_used then sign_in(user, mfa_verified: true, recovery_codes_left: result.recovery_codes_left)
    when :locked then render_locked(result)
    else render_two_factor_required(params[:code].present?)
    end
  end

  def destroy
    sign_out_current_request
    render json: { message: "Signed out successfully." }, status: :ok
  end

  private

  def sign_in(user, mfa_verified: false, **extra)
    complete_sign_in(user, mfa_verified: mfa_verified)

    render json: {
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        active_organization_id: user.active_organization&.id
      },
      two_factor: {
        enabled: user.second_factor_enabled?,
        recovery_codes_left: user.recovery_codes_remaining
      }.merge(extra)
    }, status: :ok
  end

  # Reached only when the password was right and the code was not. A client
  # that predates two-factor sends no code at all, so 401 + the flag tells it to
  # prompt for one and retry; 403 means the code it sent was simply wrong.
  def render_two_factor_required(code_was_sent)
    if code_was_sent
      render json: { error: "Invalid two-factor code.", two_factor_required: true }, status: :forbidden
    else
      render json: { error: "Two-factor authentication required.", two_factor_required: true },
        status: :unauthorized
    end
  end

  def render_locked(result)
    render json: {
      error: "Too many attempts. Sign-ins are paused for #{result.minutes_left} minutes.",
      two_factor_required: true,
      retry_after_minutes: result.minutes_left
    }, status: :too_many_requests
  end
end
