# GET /api/v1/security — the whole panel in one read: two-factor state, phone
# state, the devices this account is signed in on, and today's usage.
class Api::V1::SecurityController < ApplicationController
  include ApiSecurityResponses

  before_action :authenticate_user!

  def show
    render json: security_snapshot
  end
end
