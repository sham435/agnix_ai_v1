module Llm
  class ModelSelection
    def initialize(user:, organization:, conversation: nil)
      @user = user
      @organization = organization
      @conversation = conversation
    end

    def selected
      return @organization.settings["default_model"] || system_fallback if @conversation&.metadata&.fetch("use_organization_default", false)

      @conversation&.metadata&.dig("selected_model") ||
        @user.settings.dig("preferred_models", @organization.id.to_s) || @organization.settings["default_model"] || system_fallback
    end

    def payload(refresh: false)
      ModelCatalogue.new(@organization).call(refresh: refresh).merge(
        selected_model: selected, default_model: @organization.settings["default_model"])
    end

    def select!(provider_id:, model_id:, scope: "conversation", use_organization_default: false)
      selection = { "provider_id" => provider_id.to_s, "model_id" => model_id.to_s }
      if use_organization_default && scope != "conversation"
        raise ModelCatalogue::Error.new("invalid_scope", "Default reset is available only for a conversation.")
      end
      if use_organization_default
        selection = @organization.settings["default_model"] || system_fallback
        raise ModelCatalogue::Error.new("model_required", "No organization default or permitted system fallback is configured.") unless selection
      end
      ModelCatalogue.new(@organization).resolve!(selection)
      case scope
      when "conversation"
        raise ModelCatalogue::Error.new("conversation_required", "Choose a conversation.") unless @conversation
        @conversation.with_lock do
          metadata = @conversation.metadata.except("selected_model", "use_organization_default")
          metadata.merge!(use_organization_default ? { "use_organization_default" => true } : { "selected_model" => selection })
          @conversation.update!(metadata: metadata)
        end
      when "user"
        @user.with_lock do
          preferences = (@user.settings["preferred_models"] || {}).merge(@organization.id.to_s => selection)
          @user.update!(settings: @user.settings.merge("preferred_models" => preferences))
        end
      when "organization"
        ProviderSettings.new(organization: @organization, actor: @user).call(
          action: :default, provider_id: selection["provider_id"], model_id: selection["model_id"]
        )
      else
        raise ModelCatalogue::Error.new("invalid_scope", "Invalid model selection scope.")
      end
      selection
    end

    def snapshot!(tools: false)
      selection = selected
      raise ModelCatalogue::Error.new("model_required", "Choose a model or configure an organization default before sending a message.") unless selection
      ModelCatalogue.new(@organization).resolve!(selection, tools: tools)
      selection.deep_dup
    end

    # Availability-only snapshot for the chat path: returns nil when nothing is
    # configured so the caller can fall back to the agent's own model. Tool
    # execution is app-side (text tool_calls), so native tool capability is not
    # a precondition for sending a message.
    def snapshot
      selection = selected
      return nil unless selection

      ModelCatalogue.new(@organization).resolve!(selection)
      selection.deep_dup
    end

    private

    def system_fallback
      return unless @organization.settings["allow_system_model_fallback"] == true
      provider = ENV["SHAMS_DEFAULT_MODEL_PROVIDER"].presence
      model = ENV["SHAMS_DEFAULT_MODEL_ID"].presence
      return unless provider && model

      { "provider_id" => provider, "model_id" => model }
    end
  end
end
