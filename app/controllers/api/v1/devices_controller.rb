# The signed-in device list for API clients. A row is one sign-in; this request
# is matched to its own by the token it carries, which is what lets a client
# label one row "this device" and refuse to offer a button for the others'.
class Api::V1::DevicesController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  # Rows are looked up through this user's sessions only, so another account's
  # id answers the same way one that never existed did.
  def destroy
    device = current_user.auth_sessions.find_by(id: params[:id])
    return render json: { error: "That device is not signed in." }, status: :not_found if device.nil?

    device.update!(revoked_at: Time.current) unless device.revoked?

    if Current.auth_session&.id == device.id
      sign_out_current_request
      return render json: { message: "This device was signed out.", signed_out: true }
    end

    render json: security_snapshot.merge(message: "#{device.device} was signed out.")
  end

  # The lever for a lost laptop or an unknown device: every row is revoked and
  # the account stops accepting any session issued before this moment. It takes
  # this client's session too — that is the point — so the answer is "signed
  # out" rather than the refreshed list.
  def destroy_all
    current_user.auth_sessions.active.update_all(revoked_at: Time.current)
    current_user.update!(sessions_invalid_before: Time.current)
    sign_out_current_request

    render json: { message: "Signed out everywhere. Sign in again to continue.", signed_out: true }
  end
end
