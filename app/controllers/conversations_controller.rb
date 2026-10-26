class ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [ :show, :update, :destroy, :regenerate, :stop, :interrupt ]

  def index
    @conversations = current_user.conversations
      .where(status: "active")
      .order(updated_at: :desc)
      .includes(:agent)
  end

  # GET /conversations/search — backs the ⌘K command palette. Authorization is
  # guaranteed by scoping through current_user inside the model helper; the
  # controller only reads params and serializes.
  def search
    results = Conversation.search(current_user, params[:q], limit: 25)
    render json: {
      query: params[:q].to_s,
      results: results.map { |c| conversation_search_json(c) }
    }
  end

  def show
    @messages = @conversation.messages.order(created_at: :asc).limit(200)
  end

  def create
    @agent = Agent.find_by(id: params[:agent_id], organization: current_organization)
    return redirect_to conversations_path, alert: "Agent not found." unless @agent

    # Single startup path shared with Explore (Phase 5): conversation row,
    # optional first exchange, streaming placeholder, and the job hand-off.
    @conversation = Conversations::StartChat.call(
      user: current_user,
      agent: @agent,
      content: params[:content]
    )

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
      format.json { render json: @conversation, status: :created }
    end
  end

  def update
    @conversation.update!(conversation_params)
    respond_to do |format|
      streams = [ turbo_stream.replace("mode_toggle", partial: "conversations/mode_toggle") ]
      @conversation.agent_runs.active.each do |run|
        streams << turbo_stream.replace("agent-run-#{run.id}", partial: "agent_runs/plan_card", locals: { run: run })
      end
      format.turbo_stream { render turbo_stream: streams }
      format.html { redirect_back fallback_location: @conversation }
    end
  end

  def destroy
    @conversation.update(status: "archived")
    redirect_to conversations_path, notice: "Conversation archived."
  end

  # Regenerate the last assistant response.
  def regenerate
    redirect_to @conversation and return if request.get?

    last_assistant = @conversation.messages.where(role: "assistant").last
    return redirect_to @conversation, alert: "Nothing to regenerate." unless last_assistant

    last_assistant.destroy!
    last_user = @conversation.messages.where(role: "user").last
    return redirect_to @conversation, alert: "No user message to regenerate from." unless last_user

    AgentStreamJob.perform_later(
      conversation_id: @conversation.id,
      user_id: current_user.id,
      message_content: last_user.content
    )

    redirect_to @conversation, notice: "Regenerating response..."
  end

  def stop
    @conversation.agent_runs.active.update_all(status: "interrupted")
    head :ok
  end

  def interrupt
    @conversation.agent_runs.active.update_all(status: "interrupted")
    head :ok
  end

  private

  def conversation_search_json(conversation)
    {
      id: conversation.id,
      title: conversation.title.presence || "Untitled conversation",
      agent: conversation.agent&.name,
      updated_at: conversation.updated_at&.iso8601,
      path: conversation_path(conversation)
    }
  end

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  end

  def conversation_params
    params.require(:conversation).permit(:title, :status, :mode)
  end
end
