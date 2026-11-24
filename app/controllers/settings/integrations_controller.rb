class Settings::IntegrationsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_organization!
  before_action :require_provider_owner!, except: :index
  rescue_from Llm::ProviderSettings::Error, with: :render_provider_error

  def index
    @integrations = current_organization.tool_integrations
    @available_providers = ToolIntegration::PROVIDERS
    @plugins = Tools::Catalog.all
    @integration_by_provider = @integrations.index_by(&:provider)
    @provider_inventory = provider_settings.call if current_organization.owner_id == current_user.id
    @uncataloged_providers = @available_providers - @plugins.map { |plugin| plugin[:key] }
  end

  def save_key
    permitted = provider_params
    result = provider_settings.call(action: :save_key, **permitted.slice(:provider_id, :api_key))
    finish_provider_change(result, inventory: !Llm::ProviderRegistry.manual_only?(permitted[:provider_id]))
  end

  def connection
    finish_provider_change(provider_settings.call(action: :connection, **provider_params.slice(:provider_id, :is_active)))
  end

  def model
    finish_provider_change(provider_settings.call(action: :model, **provider_params.slice(:provider_id, :model_id, :is_active)))
  end

  def default_model
    finish_provider_change(provider_settings.call(action: :default, **provider_params.slice(:provider_id, :model_id)))
  end

  def refresh
    finish_provider_change(provider_settings.call(action: :refresh))
  end

  def save_custom
    finish_provider_change(provider_settings.call(action: :save_custom, **provider_params.slice(:provider_id, :custom_connection)))
  end

  def save_model
    finish_provider_change(provider_settings.call(action: :save_model, **provider_params.slice(:provider_id, :model_id, :model_config)))
  end

  def verify_model
    finish_provider_change(provider_settings.call(action: :verify_model, **provider_params.slice(:provider_id, :model_id)))
  end

  private

  def require_provider_owner!
    return if current_organization.owner_id == current_user.id

    render_provider_error(Llm::ProviderSettings::Error.new("owner_required", "Organization owner authorization required."))
  end

  def provider_settings
    Llm::ProviderSettings.new(organization: current_organization, actor: current_user)
  end

  def provider_params
    permitted = params.permit(
      :provider, :provider_id, :api_key, :is_active, :model_id, :disabled_models,
      custom_connection: [ :name, :base_url, :auth_mode, :api_key, :discovery_enabled,
                           :open_timeout, :read_timeout, :max_request_bytes, :max_response_bytes,
                           :max_stream_bytes, :max_retries, { headers: {}, secret_headers: {} } ],
      model_config: [ :display_name, :description, :api_family, :supports_tools, :supports_streaming,
                      :supports_vision, :supports_images, :supports_json_mode, :supports_reasoning,
                      :reasoning_parameters, :supports_parallel_tool_calls, :context_window,
                      :max_output_tokens, :free_tier, :access_restricted, :options, :rate_limits,
                      :supported_parameters, { supported_parameters: [] } ]
    ).to_h.symbolize_keys
    permitted[:provider_id] ||= permitted.delete(:provider)
    permitted
  end

  def finish_provider_change(result, inventory: true)
    respond_to do |format|
      format.html { redirect_to settings_integrations_path, notice: result[:notice], status: :see_other }
      format.json { render json: inventory ? provider_settings.call : result }
    end
  end

  def render_provider_error(error)
    status = error.code == "owner_required" ? :forbidden : :unprocessable_entity
    respond_to do |format|
      format.html { render plain: error.message, status: status }
      format.json { render json: { error_code: error.code, error: error.message }, status: status }
    end
  end
end
