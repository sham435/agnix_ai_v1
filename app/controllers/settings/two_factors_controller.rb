class Settings::TwoFactorsController < ApplicationController
  before_action :authenticate_user!

  def show
  end

  def create
    if current_user.second_factor_enabled?
      return restart_enrollment(TwoFactor::ERRORS.fetch(:already_enabled))
    end

    session.delete(:otp_enrollment_secret)
    session[:otp_enrollment] = TwoFactor.new_enrollment
    @two_factor = pending_two_factor
    response.headers["Cache-Control"] = "no-store"
    render :enroll
  end

  def confirm
    result = TwoFactor.confirm_enrollment(user: current_user, enrollment: session[:otp_enrollment],
      code: security_params[:code])
    case result.status
    when :expired, :already_enabled
      restart_enrollment(result.error)
    when :invalid, :locked
      @two_factor = pending_two_factor
      flash.now[:alert] = result.error
      response.headers["Cache-Control"] = "no-store"
      render :enroll, status: result.status == :locked ? :too_many_requests : :unprocessable_entity
    when :verified
      session.delete(:otp_enrollment)
      session.delete(:otp_enrollment_secret)
      @recovery_codes = result.recovery_codes
      response.headers["Cache-Control"] = "no-store"
      flash.now[:notice] = "Two-factor authentication is on. Save your backup codes now."
      render :show
    end
  end

  def destroy
    result = TwoFactor.disable(user: current_user, password: security_params[:password], code: security_params[:code])
    unless result.status == :verified
      return redirect_to settings_two_factor_path, alert: result.error
    end

    session.delete(:otp_enrollment)
    session.delete(:otp_enrollment_secret)
    redirect_to settings_two_factor_path, notice: "Two-factor authentication is off."
  end

  private

  def security_params
    params.permit(:password, :code)
  end

  def pending_two_factor
    TwoFactor.new(current_user, secret: session.dig(:otp_enrollment, "secret"))
  end

  def restart_enrollment(message)
    session.delete(:otp_enrollment)
    session.delete(:otp_enrollment_secret)
    redirect_to settings_two_factor_path, alert: message
  end
end
