# Two-factor enrollment and its neighbours, drawn inside the account panel.
#
# The order is the point: a secret exists only in the visitor's session until a
# code generated from it has been proved, backup codes are minted in the same
# transaction as activation, and turning the factor off costs a password — so a
# hijacked session cannot quietly remove the protection it just failed to pass.
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
    render_panel(section: "two_factor", enrolling: true)
  end

  def confirm
    enrollment = session[:otp_enrollment]
    return restart("That setup request expired. Start again.") if enrollment.blank?
    return restart("That setup request expired. Start again.") if TwoFactor.enrollment_expired?(enrollment)

    unless pending_two_factor.valid?(params[:code])
      return render_panel(section: "two_factor", enrolling: true, status: :unprocessable_entity,
        alert: "That code didn't work. Check your app and try again.")
    end

    codes = TwoFactor.activate!(current_user, enrollment.fetch("secret"))
    session.delete(:otp_enrollment)
    @recovery_codes = codes

    render_panel(section: "recovery",
      notice: "Two-factor is on. These backup codes are shown once — save them now.")
  end

  # Turning it off drops the secret and every backup code with it: without the
  # factor, those strings would be a second way in rather than a way back.
  def disable
    return wrong_password("two_factor") unless current_user.authenticate(params[:password])

    TwoFactor.disable!(current_user)
    session.delete(:otp_enrollment)

    render_panel(section: "two_factor", notice: "Two-factor authentication is off.")
  end

  # New codes, old ones gone. Proof of the password first, because this is the
  # screen that hands out sign-in shortcuts.
  def regenerate
    unless current_user.second_factor_enabled?
      return render_panel(section: "two_factor",
        alert: "Set up two-factor first — backup codes only exist to replace an authenticator.")
    end
    return wrong_password("two_factor") unless current_user.authenticate(params[:password])

    @recovery_codes = RecoveryCode.generate!(current_user)

    render_panel(section: "recovery",
      notice: "Here are your new backup codes. The old ones no longer work.")
  end

  private

  def restart(message)
    session.delete(:otp_enrollment)
    render_panel(section: "two_factor", alert: message)
  end

  def wrong_password(section)
    render_panel(section: section, status: :unprocessable_entity,
      alert: "Wrong password. Nothing was changed.")
  end
end
