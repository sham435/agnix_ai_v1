# frozen_string_literal: true

module Llm
  module InferenceTracker
    module_function

    def record(connection, model, error: nil, api_family: nil, fingerprint: nil)
      return true unless connection

      now = Time.current.iso8601
      integration = connection.respond_to?(:integration) ? connection.integration : connection
      integration.with_lock do
        integration.reload
        config = integration.config.to_h.dup
        verifications = config.fetch("inference_verifications", {}).dup
        previous = verifications.fetch(model.to_s, {}).dup
        verification = previous.merge("attempt_at" => now, "api_family" => api_family || previous["api_family"])
        verification["configuration_fingerprint"] = fingerprint if fingerprint
        if error
          verification["error_code"] = error.respond_to?(:code) ? error.code.to_s : error.to_s
          verification.delete("succeeded_at")
        else
          verification["succeeded_at"] = now
          verification["error_code"] = nil
        end
        verifications[model.to_s] = verification
        config["inference_verifications"] = verifications
        config["last_inference_attempt_at"] = now
        config["last_inference_configuration_fingerprint"] = fingerprint if fingerprint
        if error
          config["last_inference_error_code"] = verification["error_code"]
        else
          config["last_inference_error_code"] = nil
          config["last_inference_succeeded_at"] = now
          config["last_inference_model_id"] = model.to_s
        end
        integration.update_columns(config: config)
      end
      true
    rescue StandardError => e
      Rails.logger.warn "[LLM] inference-outcome-failed #{e.class}"
      false
    end
  end
end
