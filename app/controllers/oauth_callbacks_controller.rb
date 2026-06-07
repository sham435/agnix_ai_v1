class OauthCallbacksController < ApplicationController
  def create
    auth = request.env["omniauth.auth"]
    provider = auth[:provider]

    user = find_or_create_user_from_auth(auth)

    if user
      session[:user_id] = user.id
      cookies.signed[:user_id] = {
        value: user.id,
        expires: 2.weeks.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      redirect_to conversations_path, notice: "Signed in with #{provider}."
    else
      redirect_to login_path, alert: "Failed to authenticate with #{provider}."
    end
  end

  def failure
    redirect_to login_path, alert: "Authentication failed: #{params[:message]}"
  end

  def passthrough
    # Redirect to the OAuth provider.
  end

  private

  def find_or_create_user_from_auth(auth)
    # Try to find existing user by email.
    user = User.find_by(email: auth.info.email)

    return user if user

    # Create new user.
    User.create!(
      email: auth.info.email,
      name: auth.info.name || auth.info.nickname,
      password: SecureRandom.hex(32),
      role: "user"
    )
  rescue => e
    Rails.logger.error "OAuth user creation failed: #{e.message}"
    nil
  end
end
