class Agents::ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :set_agent

  def index
    @conversations = @agent.conversations
      .where(user: current_user, status: "active")
      .order(updated_at: :desc)
      .includes(:messages)
  end

  def create
    @conversation = current_user.conversations.create!(
      agent: @agent,
      title: params[:content].to_s.truncate(50, omission: "..."),
      status: "active"
    )

    if params[:content].present?
      message = @conversation.messages.create!(role: "user", content: params[:content])
      AgentStreamJob.perform_later(
        conversation_id: @conversation.id,
        user_id: current_user.id,
        message_content: message.content
      )
    end

    respond_to do |format|
      format.html { redirect_to conversation_path(@conversation) }
      format.json { render json: @conversation, status: :created }
    end
  end

  private

  def set_agent
    @agent = current_organization.agents.find(params[:agent_id])
  end
end
