class ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :update, :destroy, :regenerate, :stop, :interrupt]

  def index
    @conversations = current_user.conversations
      .where(status: "active")
      .order(updated_at: :desc)
      .includes(:agent, :messages)
  end

  def show
    @messages = @conversation.messages.order(created_at: :asc)
  end

  def create
    @agent = Agent.find_by(id: params[:agent_id], organization: current_organization)
    return redirect_to conversations_path, alert: "Agent not found." unless @agent

    @conversation = current_user.conversations.create!(
      agent: @agent,
      title: params[:content].to_s.truncate(50, omission: "...")
    )

    # Create the first user message if content was provided.
    if params[:content].present?
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
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @conversation }
      format.json { render json: @conversation, status: :created }
    end
  end

  def update
    @conversation.update!(conversation_params)
    respond_to do |format|
      streams = [turbo_stream.replace("mode_toggle", partial: "conversations/mode_toggle")]
      @conversation.agent_runs.active.each do |run|
        streams << turbo_stream.replace("agent-run-#{run.id}", partial: "agent_runs/plan_card", locals: { run: run })
      end
      format.turbo_stream { render turbo_stream: streams }
      format.html { redirect_back fallback_location: @conversation }
    end
  end

  def destroy
    @conversation.update(status: "deleted")
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

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  end

  def conversation_params
    params.require(:conversation).permit(:title, :status, :mode)
  end
end
