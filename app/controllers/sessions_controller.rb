class SessionsController < ApplicationController
  def new
    redirect_to root_path if user_signed_in?
  end

  def create
    user = User.find_by(email: params[:email].to_s.downcase)

    unless user&.authenticate(params[:password])
      flash.now[:alert] = "Invalid email or password."
      return render :new, status: :unprocessable_entity
    end

    if user.second_factor_enabled?
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

  # One box, two kinds of credential: the service decides by shape. Nothing is
  # concluded client-side, and the guesses are counted on the user's row so
  # this page cannot be refreshed into a fresh budget.
  def verify_otp
    user = pending_two_factor_user
    return redirect_to(login_path) if user.nil?

    result = TwoFactorLogin.verify(user: user, code: params[:code])

    case result.status
    when :verified
      finish_two_factor_sign_in(user, notice: "Welcome back, #{user.name}!")
    when :recovery_used
      finish_two_factor_sign_in(user,
        notice: "Signed in with a backup code. #{result.recovery_codes_left} left.")
    when :locked
      clear_two_factor_pending
      redirect_to login_path, alert: "Too many attempts. Two-factor sign-ins are paused for " \
        "#{result.minutes_left} minutes."
    else
      flash.now[:alert] = "That code didn't work. Try again — or use one of your backup codes."
      render :otp, status: :unprocessable_entity
    end
  end

  def destroy
    sign_out_current_request
    redirect_to login_path, notice: "Signed out successfully."
  end

  private

  def finish_two_factor_sign_in(user, notice:)
    clear_two_factor_pending
    complete_sign_in(user)
    redirect_to conversations_path, notice: notice
  end
end
