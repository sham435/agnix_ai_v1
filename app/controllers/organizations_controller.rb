class OrganizationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_organization, only: [ :show, :edit, :update, :destroy ]
  before_action :authorize_org_admin!, only: [ :edit, :update, :destroy ]

  def index
    @organizations = current_user.organizations.order(created_at: :desc)
  end

  def show
    @agents = @organization.agents.order(created_at: :desc)
    @members = @organization.memberships.includes(:user).order(created_at: :asc)
  end

  def new
    @organization = Organization.new
  end

  def create
    @organization = Organization.new(organization_params)
    @organization.owner = current_user

    if @organization.save
      @organization.add_user(current_user, role: "owner")
      redirect_to @organization, notice: "Organization created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @organization.update(organization_params)
      redirect_to @organization, notice: "Organization updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @organization.destroy
    redirect_to organizations_path, notice: "Organization deleted."
  end

  private

  def set_organization
    @organization = current_user.organizations.find(params[:id])
  end

  def authorize_org_admin!
    return if current_user&.admin?(@organization)
    redirect_to organization_path(@organization), alert: "Admin access required."
  end

  def organization_params
    params.require(:organization).permit(:name, :slug, :plan, settings: {})
  end
end
