class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user, only: [ :show, :update ]

  def show
    @conversations = @user.conversations.where(status: "active").order(updated_at: :desc).limit(10)
    @memories = @user.memories.order(created_at: :desc).limit(10)
  end

  def update
    if @user.update(user_params)
      redirect_to user_path(@user), notice: "Profile updated."
    else
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_user
    # Self-service only: any id that is not the signed-in user must 404
    # exactly like a nonexistent id, so accounts cannot be enumerated.
    @user = current_user if params[:id].to_s == current_user.id.to_s
    raise ActiveRecord::RecordNotFound unless @user
  end

  def user_params
    # Email is the login identity; it is editable only in Settings::Profiles
    # (current_user-scoped), never through this arbitrary-id surface.
    params.require(:user).permit(:name, settings: {})
  end
end
