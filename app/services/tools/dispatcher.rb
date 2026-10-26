# frozen_string_literal: true

require "json_schemer"

# Dispatches a namespaced plugin tool ("slack.post_message") against the
# organization's connected + active ToolIntegration row.
#
# Pipeline: catalog lookup -> JSON-schema param validation -> org-scoped
# integration resolution -> real executor class under app/services/integrations/
# -> touch_usage on a completed call. Every refusal is a bounded hash; raw
# provider errors are truncated and never leak credentials.
module Tools
  class Dispatcher
    class << self
      def call(name, arguments:, organization:, integration_id: nil, context: {})
        tool = Tools::Catalog.tool_by_namespaced_name(name)
        return refusal("unknown_tool", tool: name.to_s) unless tool

        validation = validate(tool[:parameters], arguments)
        return validation if validation

        integration = resolve_integration(tool[:plugin_key], organization, integration_id)
        return refusal("not_connected", plugin: tool[:plugin_key]) unless integration

        executor = tool[:executor].safe_constantize
        return refusal("executor_missing", tool: name.to_s) unless executor.respond_to?(:call)

        result = executor.call(integration: integration, arguments: arguments, context: context)
        result = normalize_result(result)
        integration.touch_usage if result[:ok]
        result
      rescue StandardError => e
        Rails.logger.warn "[Tools::Dispatcher] #{name} failed: #{e.class} #{e.message}"
        refusal("execution_failed", detail: e.message.to_s.truncate(200))
      end

      private

      def validate(schema, arguments)
        schemer = JSONSchemer.schema(schema)
        errors = schemer.validate(arguments.is_a?(Hash) ? arguments : {}).to_a
        return nil if errors.empty?

        { ok: false, error_code: "invalid_request", errors: errors.map { |err| err["error"] }.first(5) }
      end

      # Org-scoped by construction: only this organization's active rows for
      # this provider. An explicit integration_id resolves inside that scope,
      # so a forged id from another org can never execute; when the pinned row
      # no longer resolves (deleted or reconnected under a new id) the org's
      # active row for the provider takes over instead of dead-ending.
      def resolve_integration(plugin_key, organization, integration_id)
        scope = organization&.tool_integrations&.active&.where(provider: plugin_key.to_s)
        return nil unless scope

        if integration_id.present?
          scope.find_by(id: integration_id) || scope.first
        else
          scope.first
        end
      end

      def normalize_result(result)
        return { ok: false, error_code: "bad_executor_result" } unless result.is_a?(Hash)

        result.key?(:ok) || result.key?("ok") ? result.symbolize_keys : { ok: false, error_code: "bad_executor_result" }
      end

      def refusal(error_code, extra = {})
        { ok: false, error_code: error_code }.merge(extra)
      end
    end
  end
end
