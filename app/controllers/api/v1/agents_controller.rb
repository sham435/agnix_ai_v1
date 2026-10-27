class Api::V1::AgentsController < ApplicationController
  before_action :authenticate_user!

  def index
    @agents = current_organization.agents.order(created_at: :desc)
    render json: @agents
  end

  def show
    @agent = current_organization.agents.find(params[:id])
    render json: @agent
  end
end
