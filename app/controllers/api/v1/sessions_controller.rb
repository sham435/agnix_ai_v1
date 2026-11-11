class Api::V1::SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create

  def create
    user = User.find_by(email: params[:email].to_s.downcase)

    if user&.authenticate(params[:password])
      return render_two_factor_required if user.otp_enabled? && !user.two_factor.valid?(params[:code])

      complete_sign_in(user)

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
    clear_two_factor_pending
    cookies.delete(:user_id)
    render json: { message: "Signed out successfully." }, status: :ok
  end

  private

  # Reached only when the password was right and the code was not. A client
  # that predates two-factor sends no code at all, so 401 + the flag tells it to
  # prompt for one and retry; 403 means the code it sent was simply wrong.
  def render_two_factor_required
    if params[:code].present?
      render json: { error: "Invalid two-factor code.", two_factor_required: true }, status: :forbidden
    else
      render json: { error: "Two-factor authentication required.", two_factor_required: true },
        status: :unauthorized
    end
  end
end
