class Api::V1::MessagesController < ApplicationController
  before_action :authenticate_user!

  def create
    @conversation = current_user.conversations.find(params[:conversation_id])

    message = @conversation.messages.create!(
      role: "user",
      content: params[:content]
    )

    # Queue agent response.
    AgentStreamJob.perform_later(
      conversation_id: @conversation.id,
      user_id: current_user.id,
      message_content: message.content
    )

    render json: { message: message, status: :processing }, status: :created
  end
end
