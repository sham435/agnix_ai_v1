class Api::V1::ConversationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @conversations = current_user.conversations
      .where(status: "active")
      .order(updated_at: :desc)
      .includes(:agent)
    render json: @conversations, include: :agent
  end

  # POST /api/v1/conversations
  #
  # Starts a chat through Conversations::StartChat - the same single startup
  # path the web composer and Explore use - so title truncation, the streaming
  # assistant placeholder and the AgentStreamJob hand-off cannot drift into a
  # third variant here. content is optional: without it the client gets an
  # empty conversation and its first message goes through
  # POST /api/v1/conversations/:id/messages.
  def create
    agent = Agent.find_by(id: params[:agent_id], organization: current_organization)
    return render json: { error: "Agent not found." }, status: :not_found unless agent

    @conversation = Conversations::StartChat.call(
      user: current_user,
      agent: agent,
      content: params[:content]
    )

    render json: @conversation, status: :created
  end

  def show
    @conversation = current_user.conversations.find(params[:id])
    render json: @conversation, include: { messages: { include: :agent } }
  end
end
