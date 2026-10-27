class Api::V1::RunsController < ApplicationController
  before_action :authenticate_user!

  def show
    @run = current_organization.agents.joins(:runs).find_by!(runs: { id: params[:id] }).runs.find(params[:id])
    render json: @run
  end
end
