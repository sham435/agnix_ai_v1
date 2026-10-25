# frozen_string_literal: true

# ChatGPT-style automations inbox. Every record is hard-scoped to the signed-in
# user (never global), so cross-user access falls through to RecordNotFound and
# is redirected. Authorization scoping + orchestration only — all scheduling
# math and state transitions live in the ScheduledTask / ScheduledTaskRun models.
class ScheduledTasksController < ApplicationController
  before_action :authenticate_user!
  before_action :set_scheduled_task, only: [ :update, :destroy, :pause, :resume ]

  rescue_from ActiveRecord::RecordNotFound, with: :redirect_missing

  def index
    @scheduled_tasks = current_user.scheduled_tasks.inbox
    @active_count = current_user.scheduled_tasks.active_scheduled.count
  end

  def new
    @scheduled_task = current_user.scheduled_tasks.new(
      schedule_type: "recurring",
      timezone: default_timezone,
      prompt: params[:prompt].to_s,
      agent_id: params[:agent_id].presence
    )
  end

  def edit
    @scheduled_task = current_user.scheduled_tasks.find(params[:id])
  end

  def create
    @scheduled_task = current_user.scheduled_tasks.new(scheduled_task_params)
    assign_agent_and_organization(@scheduled_task)

    if @scheduled_task.save
      redirect_to scheduled_tasks_path, notice: "Scheduled task created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    assign_agent_and_organization(@scheduled_task)
    if @scheduled_task.update(scheduled_task_params)
      redirect_to scheduled_tasks_path, notice: "Scheduled task updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @scheduled_task.destroy
    redirect_to scheduled_tasks_path, notice: "Scheduled task deleted."
  end

  def pause
    @scheduled_task.update!(status: :paused)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: task_row_stream(@scheduled_task) }
      format.html { redirect_to scheduled_tasks_path, notice: "Task paused." }
    end
  end

  def resume
    @scheduled_task.update!(status: :active)
    @scheduled_task.compute_next_run_at!(from: Time.current)
    @scheduled_task.save!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: task_row_stream(@scheduled_task) }
      format.html { redirect_to scheduled_tasks_path, notice: "Task resumed." }
    end
  end

  private

  def set_scheduled_task
    @scheduled_task = current_user.scheduled_tasks.find(params[:id])
  end

  def redirect_missing
    redirect_to scheduled_tasks_path, alert: "Scheduled task not found."
  end

  # The agent (and therefore the owning organization) must belong to the user's
  # current organization — this is authorization, so it is checked here rather
  # than trusted from params. Organization is derived from the agent to keep the
  # two always consistent.
  def assign_agent_and_organization(task)
    agent = current_organization&.agents&.find_by(id: task.agent_id)
    if agent
      task.agent = agent
      task.organization = agent.organization
    else
      task.errors.add(:agent_id, "must be one of your organization's agents")
    end
  end

  def default_timezone
    current_user.respond_to?(:timezone) && current_user.timezone.present? ? current_user.timezone : "UTC"
  end

  def task_row_stream(task)
    turbo_stream.replace("scheduled-task-#{task.id}") do
      render partial: "scheduled_tasks/task", locals: { task: task }
    end
  end

  def scheduled_task_params
    params.require(:scheduled_task).permit(
      :name, :prompt, :schedule_type, :cron, :run_at_wall, :run_at,
      :timezone, :max_runs, :expires_at, :agent_id
    )
  end
end
