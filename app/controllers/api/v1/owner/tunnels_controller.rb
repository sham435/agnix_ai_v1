class Api::V1::Owner::TunnelsController < ApplicationController
  skip_before_action :set_current_user
  prepend_before_action :authorize_owner_operations!
  prepend_before_action :set_current_user

  def show
    response.headers["Cache-Control"] = "no-store"
    render json: Tunnel::Status.new.call
  end

  def refresh
    show
  end

  private

  def authorize_owner_operations!
    unless current_user
      return render json: { error: "Please sign in to continue." }, status: :unauthorized
    end

    allowed = OwnerOperations::Policy.allowed?(user: current_user, organization: current_organization,
      auth_session: Current.auth_session, session: session)
    allowed &&= params[:organization_id].blank? || params[:organization_id].to_s == current_organization.id.to_s
    render json: { error: "Owner authorization and verified MFA required." }, status: :forbidden unless allowed
  end
end
