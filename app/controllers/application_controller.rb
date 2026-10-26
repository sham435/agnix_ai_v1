class ApplicationController < ActionController::Base
  # Security defaults.
  allow_browser versions: :modern

  # Set current context for each request.
  before_action :set_current_user
  before_action :set_sidebar_context

  # Current user.
  helper_method :current_user, :user_signed_in?, :current_organization

  private

  def set_current_user
    if session[:user_id]
      Current.user = User.find_by(id: session[:user_id])
    elsif cookies.signed[:user_id]
      user = User.find_by(id: cookies.signed[:user_id])
      if user
        session[:user_id] = user.id
        Current.user = user
      end
    end
    Current.request_id = request.request_id
  end

  # Populate the persistent sidebar with the user's recent conversations. The
  # query itself lives in Conversation.sidebar_history (model), not here.
  def set_sidebar_context
    @sidebar_conversations = user_signed_in? ? Conversation.sidebar_history(current_user) : nil
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

    if request.format.json?
      render json: { error: "Please sign in to continue." }, status: :unauthorized
    else
      redirect_to login_path, alert: "Please sign in to continue."
    end
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
    base = params.require(:agent).permit(
      :name, :slug, :description, :system_prompt, :model, :provider, :is_active,
      config: {}
    )

    # `tools: {}` only passes a Hash and silently discards arrays, so the
    # tool list is sanitized by hand. Agent.tools stores an array mixing the
    # legacy plain-string form ("calculator") with plugin entries
    # ({ "name" => "slack.post_message", "integration_id" => "..." }) —
    # Agent#enabled_tools consumes both shapes. The form submits plugin tools
    # separately (agent[plugin_tools][]) and they are merged in here, so no
    # fragile paired Rack inputs have to reconstruct a hash client-side.
    agent_params = params[:agent]
    plain = agent_params.key?(:tools) ? sanitize_agent_tools(agent_params[:tools]) : nil
    plugin = agent_params.key?(:plugin_tools) ? plugin_tool_entries(agent_params[:plugin_tools]) : nil
    if plain || plugin
      merged = [ plain, plugin ].compact.flatten.uniq
      bound = merged.filter_map { |t| t["name"] if t.is_a?(Hash) }
      # A name arriving both as a plain string and as a plugin entry keeps
      # the hash form only — that is the one carrying the integration binding.
      base[:tools] = merged.reject { |t| t.is_a?(String) && bound.include?(t) }
    end
    base
  end

  def sanitize_agent_tools(raw)
    tool_entries(raw).filter_map do |entry|
      case entry
      when ActionController::Parameters
        allowed = entry.permit(:name, :integration_id, :enabled)
        name = allowed[:name].to_s.strip
        next nil if name.blank? || !valid_tool_name?(name)

        tool = { "name" => name }
        tool["integration_id"] = allowed[:integration_id].to_s if allowed[:integration_id].present?
        tool["enabled"] = ActiveModel::Type::Boolean.new.cast(allowed[:enabled]) unless allowed[:enabled].nil?
        tool
      when String
        clean = entry.strip
        clean.presence if valid_tool_name?(clean)
      else
        nil
      end
    end
  end

  # Dotted names belong to the plugin catalog or to nobody. Persisting an
  # unknown "evil.do_this" would advertise a tool the runner must refuse at
  # run time — keep stored configs honest instead.
  def valid_tool_name?(name)
    return true if name.blank?
    return true unless name.include?(".")

    Tools::Catalog.catalog_tool?(name)
  end

  # Plugin tool names from the marketplace picker ("slack.post_message"):
  # only catalog-known names survive, each pinned to the organization's
  # currently-active integration row for that provider.
  def plugin_tool_entries(raw)
    tool_entries(raw).filter_map do |entry|
      name =
        case entry
        when ActionController::Parameters then entry.permit(:name)[:name].to_s.strip
        when String then entry.strip
        end
      next nil if name.blank?
      next nil unless Tools::Catalog.catalog_tool?(name)

      tool = { "name" => name }
      integration = current_organization
        &.tool_integrations&.active&.find_by(provider: Tools::Catalog.provider_for(name))
      tool["integration_id"] = integration.id if integration
      tool
    end
  end

  def tool_entries(raw)
    case raw
    when ActionController::Parameters
      raw.permitted? ? raw.values : raw.permit!.values
    when Hash
      raw.values
    else
      Array(raw)
    end
  end
end
