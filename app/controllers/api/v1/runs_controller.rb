class Api::V1::RunsController < ApplicationController
  before_action :authenticate_user!

  def show
    @run = Run.in_organization(current_organization).for_user(current_user).find(params[:id])
    render json: @run
  end
end
