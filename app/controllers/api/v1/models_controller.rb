class Api::V1::ModelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_model_context
  rescue_from Llm::ModelCatalogue::Error, with: :render_model_error

  def index
    render json: selection.payload
  end

  def providers
    render json: selection.payload.slice(:providers, :catalogue_updated_at)
  end

  def refresh
    render json: selection.payload(refresh: true)
  end

  def status
    model = Llm::ModelCatalogue.new(@model_organization).resolve!(
      { "provider_id" => params[:provider_id].to_s, "model_id" => params[:id].to_s })
    render json: model
  end

  def update
    selection.select!(provider_id: params[:provider_id], model_id: params[:model_id],
      scope: params[:scope].presence || "conversation",
      use_organization_default: params[:use_organization_default] == true || params[:use_organization_default] == "true")
    render json: selection.payload
  end

  def configure
    unless @model_organization.owner_id == current_user.id
      return render json: { error_code: "owner_required", error: "Organization owner authorization required." }, status: :forbidden
    end
    permitted = params.permit(:provider_id, disabled_models: [])
    provider_settings.call(action: :models, **permitted.to_h.symbolize_keys)
    render json: selection.payload(refresh: true)
  end

  private

  def set_model_context
    @model_conversation = current_user.conversations.find(params[:conversation_id]) if params[:conversation_id].present?
    @model_organization = @model_conversation&.agent&.organization || current_organization
    unless @model_organization && (current_user.owner?(@model_organization) || current_user.organizations.exists?(id: @model_organization.id))
      return render json: { error_code: "organization_required", error: "Organization access required." }, status: :forbidden
    end
    if params[:organization_id].present? && params[:organization_id].to_s != @model_organization.id.to_s
      render json: { error_code: "organization_forbidden", error: "Organization access denied." }, status: :forbidden
    end
  end

  def selection
    Llm::ModelSelection.new(user: current_user, organization: @model_organization, conversation: @model_conversation)
  end

  def provider_settings
    Llm::ProviderSettings.new(organization: @model_organization, actor: current_user)
  end

  def render_model_error(error)
    status = error.code == "owner_required" ? :forbidden : :unprocessable_entity
    render json: { error_code: error.code, error: error.message }, status: status
  end
end
