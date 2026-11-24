# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe Llm::ProviderError do
  describe ".from_http" do
    {
      400 => [ "unsupported_parameter", "provider_parameter_unsupported", false ],
      401 => [ "invalid_api_key", "provider_authentication_failed", false ],
      402 => [ "insufficient_quota", "provider_credit_insufficient", false ],
      403 => [ "external_client_restricted", "provider_external_client_restricted", false ],
      404 => [ "model_not_found", "provider_model_not_found", false ],
      429 => [ "rate_limit_error", "provider_rate_limited", true ],
      500 => [ "server_error", "provider_unavailable", true ],
      504 => [ "server_error", "provider_timeout", true ]
    }.each do |status, (upstream_type, code, retryable)|
      it "classifies HTTP #{status} #{upstream_type} without exposing the upstream body" do
        error = described_class.from_http(status, {
          error: { type: upstream_type, message: "secret upstream detail" }
        }, request_id: "request-123")

        expect(error).to have_attributes(
          code: code, status: status, retryable?: retryable,
          provider_error_type: upstream_type, request_id: "request-123"
        )
        expect(error.message).not_to include("secret upstream detail")
      end
    end

    it "uses the status classification when the provider omits error metadata" do
      error = described_class.from_http(400, "secret upstream detail")

      expect(error.code).to eq("provider_request_rejected")
      expect(error.retryable?).to be(false)
      expect(error.message).not_to include("secret upstream detail")
    end
  end

  describe ".retry_after_seconds" do
    it "parses numeric seconds" do
      expect(described_class.retry_after_seconds({ "Retry-After" => "12.5" })).to eq(12.5)
    end

    it "parses an HTTP-date relative to the current time" do
      travel_to Time.zone.local(2026, 11, 24, 12, 0, 0) do
        headers = { "retry-after" => 30.seconds.from_now.httpdate }
        expect(described_class.retry_after_seconds(headers)).to eq(30.0)
      end
    end

    it "caps long delays" do
      expect(described_class.retry_after_seconds({ "Retry-After" => "120" })).to eq(60.0)
    end

    it "preserves an explicit zero delay" do
      expect(described_class.retry_after_seconds({ "Retry-After" => "0" })).to eq(0.0)
    end

    [ "invalid", "-1", "Infinity", "NaN" ].each do |value|
      it "ignores #{value.inspect}" do
        expect(described_class.retry_after_seconds({ "Retry-After" => value })).to be_nil
      end
    end

    it "ignores a past HTTP-date" do
      travel_to Time.zone.local(2026, 11, 24, 12, 0, 0) do
        expect(described_class.retry_after_seconds({ "Retry-After" => 1.minute.ago.httpdate })).to be_nil
      end
    end
  end

  describe ".network" do
    it "preserves a retryable connection failure without exposing its message" do
      error = described_class.network(Errno::ECONNREFUSED.new("secret socket detail"))

      expect(error).to have_attributes(code: "provider_network_error", retryable?: true)
      expect(error.connection_error?).to be(true)
      expect(error.message).not_to include("secret socket detail")
    end

    it "classifies timeouts separately" do
      error = described_class.network(Net::ReadTimeout.new("secret timeout detail"))

      expect(error.code).to eq("provider_timeout")
      expect(error.retryable?).to be(true)
      expect(error.message).not_to include("secret timeout detail")
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
