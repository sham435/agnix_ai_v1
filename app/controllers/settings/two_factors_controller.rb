class Settings::TwoFactorsController < ApplicationController
  before_action :authenticate_user!

  def show
  end

  # Generates a secret and parks it in the server-side session: nothing is
  # written to the user until they prove the authenticator actually works.
  def create
    session[:otp_enrollment_secret] = TwoFactor.generate_secret
    @two_factor = pending_two_factor
    render :enroll
  end

  def confirm
    secret = session[:otp_enrollment_secret]
    return restart_enrollment("That setup request expired. Start again.") if secret.blank?

    unless pending_two_factor.valid?(params[:code])
      @two_factor = pending_two_factor
      flash.now[:alert] = "That code didn't work. Check your app and try again."
      return render :enroll, status: :unprocessable_entity
    end

    current_user.update!(otp_secret: secret, otp_enabled: true)
    session.delete(:otp_enrollment_secret)
    redirect_to settings_two_factor_path, notice: "Two-factor authentication is on."
  end

  # Turning 2FA off is the one action that undoes the protection, so it asks for
  # the password again rather than trusting the session alone.
  def destroy
    unless current_user.authenticate(params[:password])
      return redirect_to settings_two_factor_path, alert: "Wrong password. Two-factor authentication stays on."
    end

    current_user.update!(otp_enabled: false, otp_secret: nil)
    session.delete(:otp_enrollment_secret)
    redirect_to settings_two_factor_path, notice: "Two-factor authentication is off."
  end

  private

  def pending_two_factor
    TwoFactor.new(current_user, secret: session[:otp_enrollment_secret])
  end

  def restart_enrollment(message)
    session.delete(:otp_enrollment_secret)
    redirect_to settings_two_factor_path, alert: message
  end
end
