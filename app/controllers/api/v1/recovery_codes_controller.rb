# Backup codes for API clients. They already work at sign-in — `TwoFactorLogin`
# spends one on the same POST that takes a TOTP code — so this is the one
# remaining operation: mint a fresh set, which retires the old ones.
class Api::V1::RecoveryCodesController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  def create
    result = TwoFactor.regenerate_recovery_codes(user: current_user,
      password: security_params[:password], code: security_params[:code])
    unless result.status == :verified
      status = { disabled: :conflict, locked: :too_many_requests }.fetch(result.status, :unprocessable_entity)
      return render json: { error: result.error }, status: status
    end

    response.headers["Cache-Control"] = "no-store"
    render json: security_snapshot.merge(
      message: "Here are your new backup codes. The old ones no longer work.",
      recovery_codes: result.recovery_codes
    )
  end

  private

  def security_params
    params.permit(:password, :code)
  end
end
