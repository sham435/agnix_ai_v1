class Agents::RunsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :set_agent

  def index
    @runs = @agent.runs.order(created_at: :desc).includes(:conversation).limit(100)
  end

  def show
    @run = @agent.runs.find(params[:id])
  end

  private

  def set_agent
    @agent = current_organization.agents.find(params[:agent_id])
  end
end
