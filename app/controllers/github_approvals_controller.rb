# frozen_string_literal: true

class GithubApprovalsController < ApplicationController
  before_action :authenticate_user!
  protect_from_forgery with: :exception

  def show
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    @approval_token = approval_params[:token]
    @result = Integrations::Github::Approval.call(action: :inspect, user: current_user, token: @approval_token)
    render :show, status: @result[:ok] ? :ok : :not_found
  end

  def create
    response.headers["Cache-Control"] = "no-store"
    @result = Integrations::Github::Approval.call(action: :confirm, user: current_user, token: approval_params[:token])
    render :create, status: @result[:ok] ? :ok : :unprocessable_entity
  end

  private

  def approval_params
    params.permit(:token)
  end
end
