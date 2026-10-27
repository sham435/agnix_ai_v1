class Api::V1::CsrfController < ApplicationController
  def show
    render json: { token: form_authenticity_token }
  end
end
