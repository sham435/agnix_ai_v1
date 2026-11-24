# Two-factor enrollment and fresh-proof security changes inside the account panel.
class Account::TwoFactorsController < ApplicationController
  include AccountPanelResponses

  before_action :authenticate_user!

  # Start: mint a pending secret and show the QR. Nothing has changed yet.
  def create
    if current_user.second_factor_enabled?
      return render_panel(section: "two_factor",
        alert: "Two-factor is already on. Turn it off before setting it up again.")
    end

    session[:otp_enrollment] = TwoFactor.new_enrollment
    render_sensitive_panel(section: "two_factor", enrolling: true)
  end

  def confirm
    result = TwoFactor.confirm_enrollment(user: current_user, enrollment: session[:otp_enrollment],
      code: security_params[:code])
    case result.status
    when :expired, :already_enabled
      restart(result.error)
    when :invalid, :locked
      render_sensitive_panel(section: "two_factor", enrolling: true, status: failure_status(result),
        alert: result.error)
    when :verified
      session.delete(:otp_enrollment)
      @recovery_codes = result.recovery_codes
      render_sensitive_panel(section: "recovery",
        notice: "Two-factor is on. These backup codes are shown once — save them now.")
    end
  end

  def disable
    result = TwoFactor.disable(user: current_user, password: security_params[:password], code: security_params[:code])
    return render_failure(result) unless result.status == :verified

    session.delete(:otp_enrollment)
    render_panel(section: "two_factor", notice: "Two-factor authentication is off.")
  end

  def regenerate
    result = TwoFactor.regenerate_recovery_codes(user: current_user, password: security_params[:password], code: security_params[:code])
    return render_failure(result) unless result.status == :verified

    @recovery_codes = result.recovery_codes
    render_sensitive_panel(section: "recovery",
      notice: "Here are your new backup codes. The old ones no longer work.")
  end

  private

  def restart(message)
    session.delete(:otp_enrollment)
    render_panel(section: "two_factor", alert: message)
  end

  def security_params
    params.permit(:password, :code)
  end

  def failure_status(result)
    result.status == :locked ? :too_many_requests : :unprocessable_entity
  end

  def render_failure(result)
    render_panel(section: "two_factor", status: failure_status(result), alert: result.error)
  end

  def render_sensitive_panel(section:, status: :ok, **options)
    response.headers["Cache-Control"] = "no-store"
    prepare_panel(section: section, **options)
    if turbo_frame_request?
      render "account/panels/show", layout: false, status: status
    else
      render "account/panels/page", status: status
    end
  end
end
