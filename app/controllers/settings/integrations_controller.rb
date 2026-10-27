class Settings::IntegrationsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!

  # Model providers an agent can actually run on. Derived from Agent::MODELS
  # (not the enum) so this page never offers a key slot for a provider that has
  # no models to select - an enum value with no models would be dead config.
  MODEL_PROVIDERS = Agent::MODELS.keys.map(&:to_s).freeze

  def index
    @integrations = current_organization.tool_integrations
    @available_providers = ToolIntegration::PROVIDERS
    # Plugin marketplace cards are shared with /integrations so the enable/
    # disable Turbo Stream target ids (plugin-card-<key>) exist on both pages.
    @plugins = Tools::Catalog.all
    @integration_by_provider = @integrations.index_by(&:provider)
    @model_integrations = @integrations.where(provider: MODEL_PROVIDERS).index_by(&:provider)
    # View-facing shape: ERB cannot resolve this controller's constants, so the
    # provider list (with the models each one unlocks) is handed over as ivars.
    @model_providers = MODEL_PROVIDERS.map { |provider| { key: provider, models: Agent::MODELS[provider.to_sym] } }
    @uncataloged_providers = @available_providers - @plugins.map { |plugin| plugin[:key] }
  end

  # Store (or replace) this organization's API key for a model provider.
  # `Agent#api_key` prefers an active org ToolIntegration credential over
  # Rails credentials and ENV, so this is the in-app way to swap a dead or
  # out-of-credit server key without redeploying.
  def save_key
    provider = params[:provider].to_s
    unless MODEL_PROVIDERS.include?(provider)
      return redirect_to(settings_integrations_path, alert: "Unknown provider.")
    end

    api_key = params[:api_key].to_s.strip
    if api_key.empty?
      return redirect_to(settings_integrations_path, alert: "Enter an API key before saving.")
    end

    integration = current_organization.tool_integrations
      .find_or_initialize_by(provider: provider)
    integration.name = "#{provider.titleize} API" if integration.name.blank?
    integration.credentials = integration.credentials.to_h.merge("api_key" => api_key)
    # Saving a fresh key is an explicit intent to use it, so the row is enabled
    # here; turning it off later is the existing /integrations/:id/toggle route.
    integration.is_active = true
    integration.save!

    redirect_to(settings_integrations_path, notice: "#{provider.titleize} key saved for #{current_organization.name}.")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to(settings_integrations_path, alert: "Couldn't save the key: #{e.message}")
  end
end
