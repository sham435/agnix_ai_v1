class AgentRunsController < ApplicationController
  before_action :authenticate_user!

  def resume
    agent_run = AgentRun.find(params[:id])
    return head :not_found unless agent_run.conversation.user == current_user

    AgentStreamJob.perform_later(
      conversation_id: agent_run.conversation_id,
      user_id: current_user.id,
      resume_agent_run_id: agent_run.id
    )

    redirect_to agent_run.conversation, notice: "Resuming..."
  end

  def switch_mode
    agent_run = AgentRun.find(params[:id])
    return head :not_found unless agent_run.conversation.user == current_user

    new_mode = params[:mode]
    return head :unprocessable_entity unless AgentRun::MODES.include?(new_mode)

    agent_run.update!(mode: new_mode)
    agent_run.conversation.update!(mode: new_mode)

    @conversation = agent_run.conversation

    streams = [
      turbo_stream.replace("mode_toggle", partial: "conversations/mode_toggle"),
      turbo_stream.replace("agent-run-#{agent_run.id}", partial: "agent_runs/plan_card", locals: { run: agent_run.reload })
    ]

    respond_to do |format|
      format.turbo_stream { render turbo_stream: streams }
      format.json { head :ok }
    end
  end
end
