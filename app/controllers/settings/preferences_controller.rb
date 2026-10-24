class Settings::PreferencesController < ApplicationController
  before_action :authenticate_user!

  # PATCH /settings/theme — persist the shell theme choice to the user's
  # settings jsonb. The client flips `data-theme` optimistically and calls this
  # so the preference survives a device change; the no-FOUC head script then
  # reads it back on the next full load. Accepts JSON or Turbo form posts.
  def update_theme
    theme = params[:ui_theme].to_s
    return render json: { error: "Theme must be 'dark' or 'light'." }, status: :unprocessable_entity unless %w[dark light].include?(theme)

    current_user.update!(ui_theme: theme)
    respond_to do |format|
      format.json { render json: { ui_theme: theme } }
      format.turbo_stream { head :ok }
      format.any { head :ok }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
