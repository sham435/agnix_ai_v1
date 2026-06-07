class Settings::ProfilesController < ApplicationController
  before_action :authenticate_user!

  def edit
  end

  def update
    if current_user.update(profile_params)
      redirect_to settings_profile_path, notice: "Profile updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:name, :email, settings: [:avatar, :avatar_url, :theme])
  end
end
