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

    render json: security_snapshot.merge(enrollment: {
      secret: pending.secret,
      provisioning_uri: pending.provisioning_uri,
      expires_in: TwoFactor::ENROLLMENT_TTL.to_i
    })
  end

  # Activation, and the only moment the backup codes exist in plaintext. A
  # client that loses this response has to regenerate them.
  def confirm
    enrollment = session[:otp_enrollment]
    if enrollment.blank? || TwoFactor.enrollment_expired?(enrollment)
      session.delete(:otp_enrollment)
      return render json: { error: "That setup request expired. Start again." }, status: :gone
    end

    unless TwoFactor.new(current_user, secret: enrollment.fetch("secret")).valid?(params[:code])
      return render json: { error: "That code didn't work. Check your app and try again." },
        status: :unprocessable_entity
    end

    codes = TwoFactor.activate!(current_user, enrollment.fetch("secret"))
    session.delete(:otp_enrollment)

    render json: security_snapshot.merge(
      message: "Two-factor is on. These backup codes are shown once — save them now.",
      recovery_codes: codes
    )
  end

  # Off costs the password, exactly as it does in the browser: this is the
  # change a hijacked session would most like to make.
  def destroy
    unless current_user.authenticate(params[:password])
      return render json: { error: "Wrong password. Nothing was changed." },
        status: :unprocessable_entity
    end

    TwoFactor.disable!(current_user)
    session.delete(:otp_enrollment)

    render json: security_snapshot.merge(message: "Two-factor authentication is off.")
  end
end
