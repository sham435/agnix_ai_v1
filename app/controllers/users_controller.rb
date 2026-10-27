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
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:name, :email, settings: {})
  end
end
