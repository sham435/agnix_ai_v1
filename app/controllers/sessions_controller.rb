class SessionsController < ApplicationController
  # Guesses allowed against a pending code before the sign-in restarts. Six
  # digits over a 30s window is small enough that unlimited tries are a real
  # risk, and there is no throttle middleware in this app to lean on.
  MAX_OTP_ATTEMPTS = 5

  def new
    redirect_to root_path if user_signed_in?
  end

  def create
    user = User.find_by(email: params[:email].to_s.downcase)

    unless user&.authenticate(params[:password])
      flash.now[:alert] = "Invalid email or password."
      return render :new, status: :unprocessable_entity
    end

    if user.otp_enabled?
      request_two_factor(user)
      redirect_to login_otp_path
    else
      complete_sign_in(user)
      redirect_to conversations_path, notice: "Welcome back, #{user.name}!"
    end
  end

  def otp
    redirect_to(login_path) unless pending_two_factor_user
  end

  def verify_otp
    user = pending_two_factor_user
    return redirect_to(login_path) if user.nil?

    unless user.two_factor.valid?(params[:code])
      attempts = user_attempt_count + 1
      return expired_two_factor if attempts >= MAX_OTP_ATTEMPTS

      session[:otp_attempts] = attempts
      flash.now[:alert] = "That code didn't work. Try again."
      return render :otp, status: :unprocessable_entity
    end

    complete_sign_in(user)
    redirect_to conversations_path, notice: "Welcome back, #{user.name}!"
  end

  def destroy
    session.delete(:user_id)
    clear_two_factor_pending
    cookies.delete(:user_id)
    redirect_to login_path, notice: "Signed out successfully."
  end

  private

  def user_attempt_count
    session[:otp_attempts].to_i
  end

  def expired_two_factor
    clear_two_factor_pending
    redirect_to login_path, alert: "Too many attempts. Sign in again."
  end
end
