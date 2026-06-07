class SessionsController < ApplicationController
  def new
    redirect_to root_path if user_signed_in?
  end

  def create
    user = User.find_by(email: params[:email].to_s.downcase)

    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      cookies.signed[:user_id] = {
        value: user.id,
        expires: 2.weeks.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      user.update!(last_login_at: Time.current)

      redirect_to conversations_path, notice: "Welcome back, #{user.name}!"
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session.delete(:user_id)
    cookies.delete(:user_id)
    redirect_to login_path, notice: "Signed out successfully."
  end
end
