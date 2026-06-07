class Settings::IntegrationsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!

  def index
    @integrations = current_organization.tool_integrations
    @available_providers = ToolIntegration::PROVIDERS
  end
end
