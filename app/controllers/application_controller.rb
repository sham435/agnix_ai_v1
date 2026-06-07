class ApplicationController < ActionController::Base
  # Security defaults.
  allow_browser versions: :modern

  # Set current context for each request.
  before_action :set_current_user

  # Current user.
  helper_method :current_user, :user_signed_in?, :current_organization

  private

  def set_current_user
    Current.user = User.find_by(remember_token: cookies.signed[:remember_token]) if cookies.signed[:remember_token]
    Current.request_id = request.request_id
  end

  def current_user
    Current.user
  end

  def user_signed_in?
    Current.user.present?
  end

  def current_organization
    return @current_organization if defined?(@current_organization)
    return nil unless user_signed_in?

    @current_organization = current_user.active_organization
  end

  def authenticate_user!
    return if user_signed_in?
    redirect_to login_path, alert: "Please sign in to continue."
  end

  def require_organization!
    return if current_organization
    redirect_to root_path, alert: "Please join or create an organization."
  end

  def require_admin!
    return if current_user&.admin?(current_organization)
    redirect_to root_path, alert: "Admin access required."
  end

  def set_pagination_headers(collection)
    response.headers["X-Total-Count"] = collection.total_count.to_s
    response.headers["X-Page"] = collection.page.to_s
    response.headers["X-Per-Page"] = collection.limit.to_s
  end

  def permitted_agent_params
    params.require(:agent).permit(
      :name, :slug, :description, :system_prompt, :model, :provider, :is_active,
      tools: {}, config: {}
    )
  end
end
