# The "signed-in devices" list. Each row is one sign-in, matched on the page
# that shows it by the token this request carries, and revoking it takes
# effect on that device's very next request — the cookie in its browser is
# worthless the moment the row says revoked.
class Account::DevicesController < ApplicationController
  include AccountPanelResponses

  before_action :authenticate_user!

  def destroy
    device = current_user.auth_sessions.find_by(id: params[:id])
    return render_panel(section: "devices", alert: "That device is not signed in.") if device.nil?

    device.update!(revoked_at: Time.current) unless device.revoked?

    if Current.auth_session&.id == device.id
      sign_out_current_request
      return redirect_to login_path, notice: "This device was signed out."
    end

    render_panel(section: "devices", notice: "#{device.device} was signed out.")
  end

  # The lever for a lost laptop or an unknown device: every row is revoked and
  # the account stops accepting any session issued before this moment, which
  # catches the sign-ins that predate device rows and so have no token to
  # revoke. Includes this device — that is the point.
  def close_everywhere
    current_user.auth_sessions.active.update_all(revoked_at: Time.current)
    current_user.update!(sessions_invalid_before: Time.current)
    sign_out_current_request

    redirect_to login_path, notice: "Signed out everywhere. Sign in again to continue."
  end
end
