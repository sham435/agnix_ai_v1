class ErrorsController < ApplicationController
  def not_found
    render json: { error: "Not Found", status: 404 }, status: :not_found
  end

  def internal_server_error
    render json: { error: "Internal Server Error", status: 500 }, status: :internal_server_error
  end
end
