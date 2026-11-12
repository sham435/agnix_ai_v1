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

  # Regenerate the last assistant response. All the decisions (what to replace,
  # whether a run is already in flight, the placeholder claim) live in
  # Conversations::RegenerateChat so this stays a thin flash/redirect shell.
  def regenerate
    redirect_to @conversation and return if request.get?

    outcome = Conversations::RegenerateChat.call(conversation: @conversation, user: current_user)
    flash_key = outcome.status == :queued ? :notice : :alert

    redirect_to @conversation, flash_key => outcome.message
  end

  # Stop the turn in flight. A row can only ever be a request: the run's own
  # thread decides when to look, so both flavors are marked and each notices at
  # its next checkpoint — AgentRunner re-reads its Run per iteration and per
  # streamed chunk, #execute_plan breaks on an interrupted AgentRun. The
  # broadcast is what makes the button answer at once, in every tab.
  def stop
    runs = @conversation.runs.active.to_a
    plans = @conversation.agent_runs.active.update_all(status: "interrupted")
    live = live_streaming_message
    in_flight = runs.any? || plans.positive? || live.present?

    runs.each(&:cancel!)
    broadcast_stopped(live) if in_flight

    render_stop_note(in_flight)
  end

  # The plan card's own stop path, kept identical so both entry points agree.
  def interrupt
    stop
  end

  private

  def broadcast_stopped(live_message)
    payload = { type: "stopped", conversation_id: @conversation.id }
    payload[:message_id] = live_message.id if live_message
    if live_message && live_message.metadata.is_a?(Hash) && live_message.metadata["request_id"].present?
      payload[:request_id] = live_message.metadata["request_id"]
    end
    ActionCable.server.broadcast("conversation:#{@conversation.id}", payload)
  end

  # The placeholder this conversation is currently streaming into, if any —
  # keyed so the stopped frame reaches the bubble the user is watching rather
  # than whichever one happens to carry a cursor.
  def live_streaming_message
    @conversation.messages.where(role: "assistant").order(created_at: :desc).limit(5)
      .find { |message| message.streaming? && !message.stale_streaming? }
  end

  def render_stop_note(in_flight)
    note = if in_flight
      "Stopping the current run."
    else
      "Nothing is running in this conversation."
    end

    render turbo_stream: turbo_stream.append(
      "messages-list",
      html: %(<div role="status" class="px-3.5 py-2 text-[13px] text-fg-muted rounded-lg border border-border bg-panel">#{note}</div>)
    )
  end

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
