# frozen_string_literal: true

module Llm
  class ProviderError < StandardError
    attr_reader :code, :retryable, :status, :provider_error_type, :provider_error_code, :request_id,
                :retry_after, :cause_error

    def initialize(message = "The model provider request failed.", code: nil, retryable: false,
                   status: nil, provider_error_type: nil, provider_error_code: nil, request_id: nil, retry_after: nil)
      @code = code&.to_s
      @retryable = retryable
      @status = status
      @provider_error_type = provider_error_type
      @provider_error_code = provider_error_code
      @request_id = request_id
      @retry_after = retry_after
      super(message)
    end

    def connection_error?
      cause_error.is_a?(Errno::ECONNREFUSED) || cause_error.is_a?(Errno::EHOSTUNREACH) ||
        cause_error.is_a?(Errno::ENETUNREACH)
    end

    def retryable?
      @retryable
    end

    STATUS_CODES = {
      400 => [ "provider_request_rejected", false ],
      401 => [ "provider_authentication_failed", false ],
      402 => [ "provider_credit_insufficient", false ],
      403 => [ "provider_access_restricted", false ],
      404 => [ "provider_model_not_found", false ],
      409 => [ "provider_conflict", false ],
      413 => [ "provider_request_too_large", false ],
      422 => [ "provider_request_rejected", false ],
      429 => [ "provider_rate_limited", true ],
      500 => [ "provider_unavailable", true ],
      502 => [ "provider_unavailable", true ],
      503 => [ "provider_unavailable", true ],
      504 => [ "provider_timeout", true ]
    }.freeze

    TYPE_CODES = {
      "invalid_api_key" => "provider_authentication_failed",
      "authentication_error" => "provider_authentication_failed",
      "unauthorized" => "provider_authentication_failed",
      "api_key_invalid" => "provider_authentication_failed",
      "insufficient_quota" => "provider_credit_insufficient",
      "billing_error" => "provider_credit_insufficient",
      "billing_hard_limit_reached" => "provider_credit_insufficient",
      "resource_exhausted" => "provider_credit_insufficient",
      "rate_limit_exceeded" => "provider_rate_limited",
      "rate_limit_error" => "provider_rate_limited",
      "model_not_found" => "provider_model_not_found",
      "model_unavailable" => "provider_model_unavailable",
      "context_length_exceeded" => "provider_context_length_exceeded",
      "content_policy_violation" => "provider_access_restricted",
      "permission_error" => "provider_access_restricted",
      "unsupported_parameter" => "provider_parameter_unsupported",
      "unsupported_endpoint" => "provider_endpoint_unsupported",
      "external_client_restricted" => "provider_external_client_restricted"
    }.freeze

    MESSAGES = {
      "provider_request_rejected" => "The provider rejected the request parameters.",
      "provider_authentication_failed" => "The provider rejected the configured credentials.",
      "provider_credit_insufficient" => "The provider account has insufficient credits or quota.",
      "provider_access_restricted" => "The provider account is not permitted to use this model or endpoint.",
      "provider_model_not_found" => "The provider does not offer the selected model.",
      "provider_model_unavailable" => "The selected model is unavailable. Choose another model.",
      "provider_parameter_unsupported" => "The selected model does not support one of the request parameters.",
      "provider_endpoint_unsupported" => "This provider does not support the selected API family.",
      "provider_external_client_restricted" => "This model cannot be used from an external application under the provider's access policy.",
      "provider_tool_incompatible" => "The selected model or API family does not support the requested tool workflow.",
      "provider_stream_interrupted" => "The provider stream ended before the response completed.",
      "credentials_unavailable" => "Configure a credential for this provider.",
      "provider_conflict" => "The provider reported a request conflict.",
      "provider_request_too_large" => "The request exceeds the provider's size limit.",
      "provider_context_length_exceeded" => "The conversation exceeds the model's context window.",
      "provider_rate_limited" => "The provider rate limit was reached. Try again later.",
      "provider_unavailable" => "The provider is temporarily unavailable. Try again later.",
      "provider_timeout" => "The provider did not respond in time. Try again later.",
      "provider_network_error" => "The provider could not be reached.",
      "endpoint_invalid" => "Enter a valid provider base URL.",
      "endpoint_forbidden" => "This provider endpoint is not permitted.",
      "response_too_large" => "The provider response exceeded the configured size limit.",
      "invalid_provider_response" => "The provider returned an invalid response.",
      "configuration_invalid" => "The provider connection configuration is invalid."
    }.freeze

    def self.from_http(status, body = nil, request_id: nil, headers: nil, retry_after: nil)
      metadata = error_metadata(body)
      specific = TYPE_CODES[metadata[:type]] || TYPE_CODES[metadata[:code]]
      default_code, retryable = STATUS_CODES.fetch(status.to_i, [ "provider_error", false ])
      code = specific || default_code
      code = "provider_credit_insufficient" if status.to_i == 402
      code = "provider_rate_limited" if status.to_i == 429 && code != "provider_credit_insufficient"
      new(MESSAGES.fetch(code, "The provider request failed (HTTP #{status})."),
          code: code, retryable: specific ? %w[provider_rate_limited].include?(specific) : retryable,
          status: status.to_i, provider_error_type: metadata[:type],
          provider_error_code: metadata[:code], request_id: request_id.presence,
          retry_after: retry_after || retry_after_seconds(headers))
    end

    def self.retry_after_seconds(headers)
      return unless headers.respond_to?(:[])

      value = headers["retry-after"] || headers["Retry-After"]
      return if value.blank?

      seconds = begin
        Float(value)
      rescue ArgumentError, TypeError
        Time.httpdate(value.to_s).to_f - Time.now.to_f
      end
      return unless seconds.finite? && seconds >= 0

      [ seconds, 60.0 ].min
    rescue ArgumentError, TypeError
      nil
    end

    def self.network(error)
      message = if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
                  MESSAGES["provider_timeout"]
      else
                  MESSAGES["provider_network_error"]
      end
      failure = new(message, code: message == MESSAGES["provider_timeout"] ? "provider_timeout" : "provider_network_error",
                    retryable: true)
      failure.instance_variable_set(:@cause_error, error)
      failure
    end

    def self.error_metadata(body)
      data = body.is_a?(Hash) ? body : JSON.parse(body.to_s)
      error = data.is_a?(Hash) ? (data["error"] || data[:error] || data) : {}
      error = {} unless error.is_a?(Hash)
      type = error["type"] || error[:type] || error["code"] || error[:code]
      code = error["code"] || error[:code]
      { type: type.to_s.presence, code: code.to_s.presence }
    rescue JSON::ParserError, TypeError
      {}
    end
  end
end
