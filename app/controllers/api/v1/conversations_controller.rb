class Api::V1::ConversationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @conversations = current_user.conversations
      .where(status: "active")
      .order(updated_at: :desc)
      .includes(:agent)
    render json: @conversations, each_serializer: Api::V1::ConversationSerializer
  end

  def show
    @conversation = current_user.conversations.find(params[:id])
    render json: @conversation, include: { messages: { include: :agent } }
  end
end
