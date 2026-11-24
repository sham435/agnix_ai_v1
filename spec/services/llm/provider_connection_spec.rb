# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe Llm::ProviderConnection do
  around do |example|
    original_env = ENV.to_hash
    ENV.delete("GROQ_BASE_URL")
    ENV.delete("CEREBRAS_BASE_URL")
    ENV["OPENROUTER_BASE_URL"] = "https://openrouter.ai/api/v1"
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    ENV.replace(original_env)
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def integration(config: {}, credentials: {})
    instance_double(ToolIntegration, config: config, api_key: credentials["api_key"],
                                    decrypted_credentials: credentials)
  end

  describe "registered provider routing" do
    %w[groq cerebras nvidia_nim].each do |provider|
      it "uses the exact #{provider} registry URL and bearer credential" do
        definition = Llm::ProviderRegistry::DEFINITIONS.fetch(provider)
        connection = described_class.new(provider: provider, model: "test-model", api_key: "test-only-provider-key")

        expect(connection.base_url).to eq(definition[:base_url])
        expect(connection.api_family).to eq(definition[:api_families].first)
        expect(connection.endpoint_for("chat/completions")).to eq("#{definition[:base_url]}/chat/completions")
        expect(connection.headers["Authorization"]).to eq("Bearer test-only-provider-key")
      end
    end
  end

  it "reroutes direct legacy OpenAI connections used by discovery and verification" do
    row = integration(credentials: { "api_key" => "sk-or-v1-test-only-legacy" })
    connection = described_class.new(provider: "openai", integration: row, model: "vendor/model")

    expect(connection.provider).to eq("openrouter")
    expect(connection.integration).to eq(row)
    expect(connection.endpoint_for("models")).to eq("https://openrouter.ai/api/v1/models")
    expect(connection.headers["Authorization"]).to eq("Bearer sk-or-v1-test-only-legacy")
  end

  describe "per-model configuration" do
    let(:config) do
      {
        "base_url" => "https://custom.example.test/v1",
        "models" => {
          "responses-model" => {
            "api_family" => "responses",
            "supported_parameters" => %w[input temperature max_output_tokens tools max_tokens unknown],
            "supports_tools" => true,
            "supports_streaming" => false,
            "options" => { "store" => false }
          }
        }
      }
    end
    let(:connection) do
      described_class.new(provider: "custom-acme", integration: integration(config: config), model: "responses-model")
    end

    it "selects the API family and intersects configured parameters with the family allowlist" do
      expect(connection.api_family).to eq("responses")
      expect(connection.supported_parameters).to eq(%w[input temperature max_output_tokens tools])
      expect(connection.parameter_allowed?("model")).to be(true)
      expect(connection.parameter_allowed?("max_tokens")).to be(false)
      expect(connection.parameter_allowed?("unknown")).to be(false)
      expect(connection.parameter_allowed?("stream")).to be(false)
    end

    it "exposes only declared capabilities and options" do
      expect(connection.supports?("supports_tools")).to be(true)
      expect(connection.supports?("supports_streaming")).to be(false)
      expect(connection.supports?("supports_vision")).to be_nil
      expect(connection.options).to eq("store" => false)
    end

    it "suppresses every tool parameter when tool support is explicitly false" do
      config["models"]["responses-model"]["supports_tools"] = false
      connection = described_class.new(provider: "custom-acme", integration: integration(config: config), model: "responses-model")

      expect(connection.parameter_allowed?("tools")).to be(false)
      expect(connection.parameter_allowed?("tool_choice")).to be(false)
      expect(connection.parameter_allowed?("parallel_tool_calls")).to be(false)
    end

    it "rejects an API family the provider does not support" do
      expect do
        described_class.new(provider: "groq", model: "test-model", model_config: { "api_family" => "responses" })
      end.to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("configuration_invalid") }
    end
  end

  describe ".resolve" do
    let(:organization) do
      create(:organization, owner: create(:user, email: "provider-owner@example.test"), slug: "provider-resolution-org")
    end

    before do
      ENV.delete("GROQ_API_KEY")
      ENV.delete("BONSAI_API_KEY")
      ENV.delete("SHAMS_DEFAULT_MODEL_PROVIDER")
      ENV.delete("SHAMS_DEFAULT_MODEL_ID")
      ENV["OPENROUTER_BASE_URL"] = "https://openrouter.ai/api/v1"
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("groq").and_return(nil)
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("openai").and_return(nil)
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("bonsai").and_return(nil)
    end

    it "does not expose server credentials without explicit fallback permission" do
      ENV["GROQ_API_KEY"] = "test-only-environment-key"
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("groq").and_return("test-only-rails-key")

      resolved = described_class.resolve(organization: organization, provider: "groq", model: "test-model")

      expect(resolved.api_key).to be_nil
      expect(resolved.headers).not_to have_key("Authorization")
    end

    it "uses server credentials only for the opted-in system provider and model" do
      organization.update!(settings: { "allow_system_model_fallback" => true })
      ENV["SHAMS_DEFAULT_MODEL_PROVIDER"] = "groq"
      ENV["SHAMS_DEFAULT_MODEL_ID"] = "test-model"
      ENV["GROQ_API_KEY"] = "test-only-environment-key"

      expect(described_class.resolve(organization: organization, provider: "groq", model: "test-model").api_key)
        .to eq("test-only-environment-key")
      expect(described_class.resolve(organization: organization, provider: "groq", model: "other-model").api_key).to be_nil

      ENV.delete("GROQ_API_KEY")
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("groq").and_return("test-only-rails-key")
      expect(described_class.resolve(organization: organization, provider: "groq", model: "test-model").api_key)
        .to eq("test-only-rails-key")
      expect(described_class.resolve(organization: organization, provider: "cerebras", model: "test-model").api_key).to be_nil
    end

    it "prefers an active organization key over fallback credentials" do
      row = create(:tool_integration, organization: organization, provider: "groq",
                                     credentials: { "api_key" => "test-only-organization-key" })
      ENV["GROQ_API_KEY"] = "test-only-environment-key"

      resolved = described_class.resolve(organization: organization, provider: "groq", model: "test-model")
      expect(resolved.api_key).to eq("test-only-organization-key")
      expect(resolved.integration).to eq(row)
    end

    it "does not use stored or fallback credentials for a disabled row unless a key is explicitly supplied" do
      row = create(:tool_integration, organization: organization, provider: "groq", is_active: false,
                                     credentials: { "api_key" => "test-only-disabled-key" })
      ENV["GROQ_API_KEY"] = "test-only-environment-key"

      resolved = described_class.resolve(organization: organization, provider: "groq", model: "test-model")
      expect(resolved.api_key).to be_nil
      expect(resolved.integration).to be_nil
      expect(resolved.headers).not_to have_key("Authorization")

      explicit = described_class.resolve(organization: organization, provider: "groq", model: "test-model",
                                         api_key: "test-only-explicit-key")
      expect(explicit.api_key).to eq("test-only-explicit-key")
      expect(explicit.integration).to be_nil
      expect(row.reload.is_active?).to be(false)
    end

    it "uses Bonsai's synthetic local key without a stored credential" do
      resolved = described_class.resolve(organization: organization, provider: "bonsai", model: "bonsai-2-27b")

      expect(resolved.api_key).to eq("local")
      expect(resolved.base_url).to eq("http://127.0.0.1:8080/v1")
    end

    it "lets an environment or organization key override Bonsai's synthetic default" do
      ENV["BONSAI_API_KEY"] = "test-only-environment-key"
      expect(described_class.resolve(organization: organization, provider: "bonsai", model: "bonsai-27b").api_key)
        .to eq("test-only-environment-key")

      row = create(:tool_integration, organization: organization, provider: "bonsai",
                                     credentials: { "api_key" => "test-only-organization-key" })
      resolved = described_class.resolve(organization: organization, provider: "bonsai", model: "bonsai-27b")
      expect(resolved.api_key).to eq("test-only-organization-key")
      expect(resolved.integration).to eq(row)
    end

    it "does not let Bonsai's synthetic key bypass a disabled organization row" do
      create(:tool_integration, organization: organization, provider: "bonsai", is_active: false)

      resolved = described_class.resolve(organization: organization, provider: "bonsai", model: "bonsai-27b")

      expect(resolved.api_key).to be_nil
      expect(resolved.integration).to be_nil
    end

    it "reroutes a persisted legacy OpenAI key to OpenRouter without rewriting the row" do
      row = create(:tool_integration, organization: organization, provider: "openai",
                                     credentials: { "api_key" => "sk-or-v1-test-only-legacy" })

      resolved = described_class.resolve(organization: organization, provider: "openai", model: "vendor/model")
      expect(resolved.provider).to eq("openrouter")
      expect(resolved.integration).to eq(row)
      expect(resolved.base_url).to eq("https://openrouter.ai/api/v1")
      expect(resolved.headers["Authorization"]).to eq("Bearer sk-or-v1-test-only-legacy")
      expect(row.reload.provider).to eq("openai")
    end
  end

  describe "base URL normalization" do
    {
      "https://api.openai.com/v1/v1/chat/completions" => "https://api.openai.com/v1",
      "https://api.openai.com/v1/chat/completions" => "https://api.openai.com/v1",
      "https://api.openai.com/v1/responses" => "https://api.openai.com/v1",
      "https://api.groq.com/openai/v1/models" => "https://api.groq.com/openai/v1",
      "https://generativelanguage.googleapis.com/v1beta/openai/v1" => "https://generativelanguage.googleapis.com/v1beta/openai",
      "https://proxy.example.test/team/models" => "https://proxy.example.test/team/models"
    }.each do |configured, normalized|
      it "normalizes #{configured} without changing unrelated path segments" do
        connection = described_class.new(provider: "openai", model: "test-model", api_key: "test-only-key", base_url: configured)
        expect(connection.base_url).to eq(normalized)
      end
    end

    it "leaves Bonsai URLs untouched apart from trailing slashes" do
      configured = "http://127.0.0.1:8080/v1/v1/chat/completions/"
      connection = described_class.new(provider: "bonsai", model: "bonsai-2-27b", base_url: configured)
      expect(connection.base_url).to eq(configured.delete_suffix("/"))
    end
  end

  describe "inference fingerprints" do
    let(:key) { "test-only-fingerprint-key" }
    let(:secret) { "test-only-fingerprint-secret" }
    let(:config) do
      {
        "base_url" => "https://custom.example.test/v1", "auth_mode" => "bearer",
        "headers" => { "HTTP-Referer" => "https://app.example.test" }, "read_timeout" => 20,
        "models" => { "test-model" => { "api_family" => "responses", "options" => { "store" => false } } }
      }
    end
    let(:credentials) { { "api_key" => key, "secret_headers" => { "X-Title" => secret } } }
    let(:connection) do
      described_class.new(provider: "custom-acme", integration: integration(config: config, credentials: credentials),
                          model: "test-model")
    end

    it "is stable for identical configuration and does not disclose secrets" do
      same = described_class.new(provider: "custom-acme", integration: integration(config: config, credentials: credentials),
                                 model: "test-model")

      expect(connection.inference_fingerprint).to eq(same.inference_fingerprint)
      expect(connection.inference_fingerprint).to match(/\A[0-9a-f]{64}\z/)
      expect(connection.inference_fingerprint).not_to include(key, secret, config["base_url"])
    end

    it "changes when credentials, headers, endpoint, limits, model, or model metadata change" do
      original = connection.inference_fingerprint
      changed_credentials = credentials.merge("api_key" => "test-only-replacement-key")
      changed_secrets = credentials.merge("secret_headers" => { "X-Title" => "test-only-replacement-secret" })
      changed_headers = config.merge("headers" => { "HTTP-Referer" => "https://other.example.test" })
      changed_endpoint = config.merge("base_url" => "https://other.example.test/v1")
      changed_limit = config.merge("read_timeout" => 30)
      changed_model_config = config.deep_merge("models" => { "test-model" => { "options" => { "store" => true } } })
      variants = [
        integration(config: config, credentials: changed_credentials),
        integration(config: config, credentials: changed_secrets),
        integration(config: changed_headers, credentials: credentials),
        integration(config: changed_endpoint, credentials: credentials),
        integration(config: changed_limit, credentials: credentials),
        integration(config: changed_model_config, credentials: credentials)
      ]

      fingerprints = variants.map do |changed|
        described_class.new(provider: "custom-acme", integration: changed, model: "test-model").inference_fingerprint
      end
      fingerprints << described_class.new(provider: "custom-acme", integration: integration(config: config, credentials: credentials),
                                          model: "other-model").inference_fingerprint

      expect(fingerprints).not_to include(original)
      expect(fingerprints.uniq.length).to eq(fingerprints.length)
    end
  end

  describe "bounded transport settings" do
    def connection_with(config)
      described_class.new(provider: "custom-acme", integration: integration(config: {
        "base_url" => "https://custom.example.test/v1"
      }.merge(config)))
    end

    it "uses bounded defaults" do
      connection = connection_with({})

      expect([ connection.open_timeout, connection.read_timeout, connection.max_request_bytes,
               connection.max_response_bytes, connection.max_stream_bytes, connection.max_retries ])
        .to eq([ 10, 120, 8.megabytes, 2.megabytes, 16.megabytes, 3 ])
    end

    it "clamps oversized values to the configured maxima" do
      connection = connection_with("open_timeout" => 99_999, "read_timeout" => 99_999,
                                   "max_request_bytes" => 99.megabytes, "max_response_bytes" => 99.megabytes,
                                   "max_stream_bytes" => 99.megabytes, "max_retries" => 99)

      expect([ connection.open_timeout, connection.read_timeout, connection.max_request_bytes,
               connection.max_response_bytes, connection.max_stream_bytes, connection.max_retries ])
        .to eq([ 60, 3600, 32.megabytes, 16.megabytes, 64.megabytes, 3 ])
    end

    it "clamps negative values to minima and falls back for malformed values" do
      low = connection_with("open_timeout" => -1, "read_timeout" => -1, "max_request_bytes" => 0,
                            "max_response_bytes" => 0, "max_stream_bytes" => 0, "max_retries" => -1)
      malformed = connection_with("open_timeout" => "nope", "read_timeout" => "nope")

      expect([ low.open_timeout, low.read_timeout, low.max_request_bytes, low.max_response_bytes,
               low.max_stream_bytes, low.max_retries ]).to eq([ 1, 1, 1024, 1024, 1024, 0 ])
      expect([ malformed.open_timeout, malformed.read_timeout ]).to eq([ 10, 120 ])
    end
  end

  describe "authentication and headers" do
    it "preserves a blank API key as unconfigured instead of inventing a credential" do
      connection = described_class.new(provider: "groq", model: "test-model", api_key: "   ")

      expect(connection.api_key).to be_nil
      expect(connection.auth_mode).to eq("none")
      expect(connection.headers).not_to have_key("Authorization")
    end

    it "uses Anthropic's native API key header without also sending a bearer credential" do
      connection = described_class.new(provider: "anthropic", model: "claude-test", api_key: "test-only-key")

      expect(connection.auth_mode).to eq("x-api-key")
      expect(connection.headers["X-Api-Key"]).to eq("test-only-key")
      expect(connection.headers).not_to have_key("Authorization")
    end

    it "supports explicit x-api-key and unauthenticated custom connections" do
      keyed = described_class.new(provider: "custom-acme", model: "test-model", api_key: "test-only-key",
                                  integration: integration(config: {
                                    "base_url" => "https://custom.example.test/v1", "auth_mode" => "x-api-key"
                                  }))
      anonymous = described_class.new(provider: "custom-acme", model: "test-model", integration: integration(config: {
        "base_url" => "https://custom.example.test/v1", "auth_mode" => "none"
      }))

      expect(keyed.headers["X-Api-Key"]).to eq("test-only-key")
      expect(keyed.headers).not_to have_key("Authorization")
      expect(anonymous.auth_mode).to eq("none")
      expect(anonymous.headers.values).not_to include("test-only-key")
    end

    it "merges documented headers, applies encrypted secret headers, and drops protected names" do
      credentials = { "api_key" => "test-only-provider-key", "secret_headers" => {
        "X-Title" => "test-only-secret-title", "Authorization" => "must-not-override"
      } }
      config = {
        "base_url" => "https://custom.example.test/v1", "auth_mode" => "bearer",
        "headers" => { "HTTP-Referer" => "https://app.example.test", "Host" => "must-not-override",
                       "X-Not-Allowlisted" => "must-not-send" }
      }
      connection = described_class.new(provider: "custom-acme",
                                       integration: integration(config: config, credentials: credentials))

      expect(connection.headers).to include(
        "Authorization" => "Bearer test-only-provider-key",
        "HTTP-Referer" => "https://app.example.test",
        "X-Title" => "test-only-secret-title",
        "Content-Type" => "application/json"
      )
      expect(connection.headers).not_to have_key("Host")
      expect(connection.headers).not_to have_key("X-Not-Allowlisted")
    end

    it "rejects CRLF in an accepted header value" do
      connection = described_class.new(provider: "custom-acme", integration: integration(config: {
        "base_url" => "https://custom.example.test/v1", "auth_mode" => "none",
        "headers" => { "X-Title" => "safe\r\nX-Injected: true" }
      }))

      expect { connection.headers }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("configuration_invalid")
        expect(error.message).not_to include("X-Injected")
      }
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
