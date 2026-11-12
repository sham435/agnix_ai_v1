# Backup codes for API clients. They already work at sign-in — `TwoFactorLogin`
# spends one on the same POST that takes a TOTP code — so this is the one
# remaining operation: mint a fresh set, which retires the old ones.
class Api::V1::RecoveryCodesController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  def create
    unless current_user.second_factor_enabled?
      return render json: {
        error: "Set up two-factor first — backup codes only exist to replace an authenticator."
      }, status: :conflict
    end
    unless current_user.authenticate(params[:password])
      return render json: { error: "Wrong password. Nothing was changed." },
        status: :unprocessable_entity
    end

    render json: security_snapshot.merge(
      message: "Here are your new backup codes. The old ones no longer work.",
      recovery_codes: RecoveryCode.generate!(current_user)
    )
  end
end
