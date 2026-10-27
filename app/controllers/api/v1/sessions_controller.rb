class Api::V1::SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create

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

      render json: {
        user: {
          id: user.id,
          name: user.name,
          email: user.email,
          active_organization_id: user.active_organization&.id
        }
      }, status: :ok
    else
      render json: { error: "Invalid email or password." }, status: :unauthorized
    end
  end

  def destroy
    session.delete(:user_id)
    cookies.delete(:user_id)
    render json: { message: "Signed out successfully." }, status: :ok
  end
end
