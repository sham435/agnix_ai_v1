class ToolIntegrationsController < ApplicationController
  # Every credential key the catalog and the legacy manual form can write.
  CREDENTIAL_KEYS = %w[api_key webhook_secret].freeze
  # Non-secret configuration only; anything else is dropped before storage.
  CONFIG_KEYS = %w[webhook_url timeout phone_number_id from_address].freeze

  before_action :authenticate_user!
  before_action :require_organization!
  before_action :require_integration_admin!
  before_action :set_integration, only: [ :show, :edit, :update, :destroy, :toggle ]

  def index
    @integrations = current_organization.tool_integrations.order(created_at: :desc)
    @available_providers = ToolIntegration::PROVIDERS
    # Phase 4 marketplace: catalog cards drive the grid; org rows decide the
    # Connected / Not connected state per plugin.
    @plugins = Tools::Catalog.all
    @integration_by_provider = @integrations.index_by(&:provider)
  end

  def show
  end

  def new
    @integration = current_organization.tool_integrations.new(provider: params[:provider])
    @available_providers = ToolIntegration::PROVIDERS
  end

  def create
    @integration = current_organization.tool_integrations.new(integration_params)
    assign_credentials(@integration)

    if @integration.save
      redirect_to @integration, notice: "Integration created."
    else
      @available_providers = ToolIntegration::PROVIDERS
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @available_providers = ToolIntegration::PROVIDERS
  end

  def update
    assign_credentials(@integration)

    if @integration.update(integration_params)
      redirect_to @integration, notice: "Integration updated."
    else
      @available_providers = ToolIntegration::PROVIDERS
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @integration.destroy
    redirect_to tool_integrations_path, notice: "Integration removed."
  end

  # Marketplace credential editor rendered into the layout's "modal" turbo
  # frame. Handles both first-time connect (POST -> create) and editing an
  # existing connection (PATCH -> update) from one catalog-driven form. The
  # legacy new/edit/show actions stay untouched for billing/webhook paths.
  def connect
    @plugin = Tools::Catalog.find(params[:key])
    return head(:not_found) unless @plugin

    @integration = current_organization.tool_integrations.find_by(provider: @plugin[:key]) ||
      current_organization.tool_integrations.new(provider: @plugin[:key], name: @plugin[:name])
    @connecting = @integration.new_record?
  end

  # Plugin detail modal: plain-language tool list straight from the catalog.
  def plugin
    @plugin = Tools::Catalog.find(params[:key])
    return head(:not_found) unless @plugin

    @integration = current_organization.tool_integrations.find_by(provider: @plugin[:key])
  end

  # On/off switch for the marketplace card. Org-scoped lookup by id means a
  # row from another organization 404s before anything is touched.
  def toggle
    @integration.toggle_active!
    plugin = Tools::Catalog.find(@integration.provider)
    # Rows toggled from Settings › Integrations are model provider credentials,
    # not catalog plugins — say what was actually switched.
    subject = plugin ? "#{plugin[:name]} plugin" : @integration.name
    notice = "#{subject} #{@integration.is_active? ? "enabled" : "disabled"}."

    respond_to do |format|
      if plugin
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "plugin-card-#{plugin[:key]}",
            partial: "tool_integrations/plugin_card",
            locals: { plugin: plugin, integration: @integration }
          )
        end
      end
      format.html { redirect_back_or_to tool_integrations_path, notice: notice }
    end
  end

  private

  # Org credentials are admin/owner territory: a plain member must not be
  # able to read, replace, pause or delete the keys the whole org runs on.
  def require_integration_admin!
    return if current_user.admin?(current_organization) || current_user.owner?(current_organization)

    redirect_to conversations_path, alert: "Admin access required."
  end

  def set_integration
    @integration = current_organization.tool_integrations.find(params[:id])
  end

  def integration_params
    attrs = params.require(:tool_integration).permit(:name, :provider, :is_active, config: {})
    attrs[:config] = attrs[:config].slice(*CONFIG_KEYS) if attrs[:config]
    attrs
  end

  # Secrets are write-only: a blank field keeps the stored value (so saving
  # the manage form never wipes keys it did not resubmit), unknown keys are
  # dropped, and no view renders a credential back into HTML.
  def assign_credentials(integration)
    submitted = params.dig(:tool_integration, :credentials)
    return unless submitted.respond_to?(:each_pair)

    merged = integration.credentials.is_a?(Hash) ? integration.credentials.dup : {}
    submitted.each_pair do |key, value|
      merged[key.to_s] = value if CREDENTIAL_KEYS.include?(key.to_s) && value.present?
    end
    integration.credentials = merged
  end
end
