# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sensitive parameter filtering" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  let(:filtered) do
    filter.filter({
      email: "owner@example.test", otp: "123456", ssn: "123-45-6789", code: "recovery-code",
      session: { "auth_token" => "device-token" }, messages: [ { content: "private prompt" } ],
      content: "private message", credentials: { "api_key" => "provider-key" }, model: "bonsai-2-27b"
    }.with_indifferent_access)
  end
  let(:expected) do
    {
      "email" => "[FILTERED]", "otp" => "[FILTERED]", "ssn" => "[FILTERED]", "code" => "[FILTERED]",
      "session" => "[FILTERED]", "messages" => "[FILTERED]", "content" => "[FILTERED]",
      "credentials" => "[FILTERED]", "model" => "bonsai-2-27b"
    }
  end

  it "redacts credentials, identity data, sessions, codes, and message content" do
    expect(filtered).to include(expected)
  end
end
