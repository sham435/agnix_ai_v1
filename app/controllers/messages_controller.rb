class MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation

  def create
    @message = @conversation.messages.build(
      role: "user",
      content: message_params[:content]
    )

    if @message.save
      # Stream the agent response via Action Cable.
      AgentStreamJob.perform_later(
        conversation_id: @conversation.id,
        user_id: current_user.id,
        message_content: @message.content
      )

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to conversation_path(@conversation) }
        format.json { render json: @message, status: :created }
      end
    else
      render json: { errors: @message.errors }, status: :unprocessable_entity
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end

  def message_params
    params.require(:message).permit(:content)
  end
end
