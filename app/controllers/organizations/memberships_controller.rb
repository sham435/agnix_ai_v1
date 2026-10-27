class Organizations::MembershipsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_organization
  before_action -> { redirect_to organization_path(@organization), alert: "Admin access required." unless current_user&.admin?(@organization) }

  def index
    @memberships = @organization.memberships.includes(:user).order(created_at: :asc)
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)

    if user && @organization.memberships.create(user: user, role: params[:role].presence || "member")
      redirect_to organization_memberships_path(@organization), notice: "#{user.name} added to the organization."
    else
      redirect_to organization_memberships_path(@organization), alert: user ? "Could not add member." : "No user found with that email."
    end
  end

  def update
    @membership = @organization.memberships.find(params[:id])
    if @membership.update(role: params[:membership]&.fetch(:role, nil).presence || params[:role])
      redirect_to organization_memberships_path(@organization), notice: "Membership updated."
    else
      redirect_to organization_memberships_path(@organization), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def destroy
    @membership = @organization.memberships.find(params[:id])
    @membership.destroy
    redirect_to organization_memberships_path(@organization), notice: "Member removed."
  end

  private

  def set_organization
    @organization = current_user.organizations.find(params[:organization_id])
  end
end
