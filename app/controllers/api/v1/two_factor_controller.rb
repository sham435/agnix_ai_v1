# Two-factor over the API: the same three steps the panel walks through, with
# the same meaning. A pending key lives in this client's session and changes
# nothing on the account until a code generated from it is proved here.
class Api::V1::TwoFactorController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  # Hands back what an authenticator app needs to add an account. On a phone
  # there is nothing to scan with, so the manual key travels next to the
  # otpauth:// URI and the client offers whichever of the two it can.
  def create
    if current_user.second_factor_enabled?
      return render json: { error: "Two-factor is already on. Turn it off before setting it up again." },
        status: :conflict
    end

    session[:otp_enrollment] = TwoFactor.new_enrollment
    pending = TwoFactor.new(current_user, secret: session.dig(:otp_enrollment, "secret"))

    response.headers["Cache-Control"] = "no-store"
    render json: security_snapshot.merge(enrollment: {
      secret: pending.secret,
      provisioning_uri: pending.provisioning_uri,
      expires_in: TwoFactor::ENROLLMENT_TTL.to_i
    })
  end

  # Activation, and the only moment the backup codes exist in plaintext. A
  # client that loses this response has to regenerate them.
  def confirm
    result = TwoFactor.confirm_enrollment(user: current_user, enrollment: session[:otp_enrollment],
      code: security_params[:code])
    session.delete(:otp_enrollment) if result.status.in?([ :verified, :expired, :already_enabled ])
    return render_failure(result) unless result.status == :verified

    response.headers["Cache-Control"] = "no-store"
    render json: security_snapshot.merge(
      message: "Two-factor is on. These backup codes are shown once — save them now.",
      recovery_codes: result.recovery_codes
    )
  end

  def destroy
    result = TwoFactor.disable(user: current_user, password: security_params[:password], code: security_params[:code])
    return render_failure(result) unless result.status == :verified

    session.delete(:otp_enrollment)
    render json: security_snapshot.merge(message: "Two-factor authentication is off.")
  end

  private

  def security_params
    params.permit(:password, :code)
  end

  def render_failure(result)
    status = { expired: :gone, already_enabled: :conflict, disabled: :conflict,
               locked: :too_many_requests }.fetch(result.status, :unprocessable_entity)
    render json: { error: result.error }, status: status
  end
end
