class Organizations::MembershipsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_organization
  before_action -> { redirect_to organization_path(@organization), alert: "Admin access required." unless current_user&.admin?(@organization) }
  before_action :set_membership, only: [ :update, :destroy ]

  def index
    @memberships = @organization.memberships.includes(:user).order(created_at: :asc)
  end

  def create
    attrs = params.permit(:email, :role)
    user = User.find_by(email: attrs[:email].to_s.strip.downcase)
    role = attrs[:role].presence || "member"

    unless Membership::ASSIGNABLE_ROLES.include?(role)
      return redirect_to organization_memberships_path(@organization), alert: "Only member and admin roles can be assigned."
    end

    if user && @organization.memberships.create(user: user, role: role)
      redirect_to organization_memberships_path(@organization), notice: "#{user.name} added to the organization."
    else
      redirect_to organization_memberships_path(@organization), alert: user ? "Could not add member." : "No user found with that email."
    end
  end

  def update
    role = membership_params[:role].presence || params.permit(:role)[:role]

    unless Membership::ASSIGNABLE_ROLES.include?(role)
      return redirect_to organization_memberships_path(@organization), alert: "Only member and admin roles can be assigned."
    end

    if @membership.update(role: role)
      redirect_to organization_memberships_path(@organization), notice: "Membership updated."
    else
      redirect_to organization_memberships_path(@organization), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def destroy
    if @membership.destroy
      redirect_to organization_memberships_path(@organization), notice: "Member removed."
    else
      redirect_to organization_memberships_path(@organization), alert: @membership.errors.full_messages.to_sentence
    end
  end

  private

  def set_organization
    @organization = current_user.organizations.find(params[:organization_id])
  end

  def set_membership
    @membership = @organization.memberships.find(params[:id])
  end

  def membership_params
    return ActionController::Parameters.new unless params[:membership].respond_to?(:permit)

    params[:membership].permit(:role)
  end
end
