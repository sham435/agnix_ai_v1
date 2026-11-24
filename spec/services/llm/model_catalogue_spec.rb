# rubocop:disable RSpec/ExampleLength, RSpec/LetSetup, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe Llm::ModelCatalogue do
  subject(:catalogue) { described_class.new(organization) }

  let(:organization) do
    create(:organization, owner: create(:user, email: "model-catalogue-owner@example.test"), slug: "model-catalogue-org")
  end
  let(:bonsai_url) { "http://127.0.0.1:8080/v1/models" }

  before do
    Rails.cache.clear
    stub_request(:get, bonsai_url).to_return(status: 200, body: { data: [ { id: "/private/model.gguf", meta: { n_ctx: 32768 } } ] }.to_json)
  end

  describe ".redact" do
    it "removes complete secrets from values and nested hash keys" do
      secrets = [ "test-only-api-key", "test-only-header-secret" ]
      payload = {
        "safe" => "visible",
        "nested" => {
          "prefix-test-only-api-key" => "must-disappear-with-the-key",
          "header" => "Bearer test-only-header-secret",
          "deeper" => [ { "test-only-header-secret" => "hidden", "safe" => "kept" } ]
        }
      }

      redacted = described_class.redact(payload, secrets)
      expect(redacted["safe"]).to eq("visible")
      expect(redacted["nested"]).to eq("deeper" => [ { "safe" => "kept" } ])
      expect(redacted.to_json).not_to include(*secrets)
    end
  end

  it "preserves array-valued reasoning parameters alongside boolean capabilities" do
    rows = catalogue.send(:sanitize_rows, [ {
      "id" => "reasoning-model", "supports_reasoning" => true, "reasoning_parameters" => [ "effort" ],
      "supported_parameters" => [ "temperature" ]
    } ], [])

    expect(rows.first).to include("supports_reasoning" => true, "reasoning_parameters" => [ "effort" ],
                                 "supported_parameters" => [ "temperature" ])
  end

  it "discovers Bonsai with the existing canonical alias and no host paths" do
    expect(catalogue.call[:models].first).to include(model_id: "bonsai-2-27b", context_window: 32768, supports_tools: nil)
  end

  it "does not expose the server model path" do
    expect(catalogue.call.to_json).not_to include("/private/")
  end

  it "refreshes the provider catalogue" do
    catalogue.call
    catalogue.call(refresh: true)
    expect(a_request(:get, bonsai_url)).to have_been_made.twice
  end

  it "caches discovery briefly" do
    2.times { catalogue.call }
    expect(a_request(:get, bonsai_url)).to have_been_made.once
  end

  it "expires stale discovery" do
    catalogue.call
    travel 6.minutes
    catalogue.call
    expect(a_request(:get, bonsai_url)).to have_been_made.twice
  end

  it "rejects unavailable selections" do
    expect { catalogue.resolve!({ "provider_id" => "anthropic", "model_id" => "unconnected" }) }.to raise_error(described_class::Error, /unavailable/)
  end

  it "rejects unknown tool support" do
    expect { catalogue.resolve!({ "provider_id" => "bonsai", "model_id" => "bonsai-2-27b" }, tools: true) }.to raise_error(described_class::Error, /Tool support/)
  end

  context "with an environment-configured Groq provider" do
    let(:environment_key) { "test-only-environment-groq-key" }
    let(:organization_key) { "test-only-organization-groq-key" }
    let(:groq_url) { "https://api.groq.com/openai/v1/models" }

    around do |example|
      original_env = ENV.to_hash
      ENV["GROQ_API_KEY"] = environment_key
      ENV["GROQ_BASE_URL"] = "https://api.groq.com/openai/v1"
      example.run
    ensure
      ENV.replace(original_env)
    end

    before do
      stub_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{environment_key}" })
        .to_return(status: 200, body: { data: [ { id: "groq-test-model" } ] }.to_json)
      stub_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{organization_key}" })
        .to_return(status: 200, body: { data: [ { id: "groq-test-model" } ] }.to_json)
    end

    it "discovers a built-in provider configured only through the environment" do
      expect(catalogue.call[:models]).to include(hash_including(
        provider_id: "groq", model_id: "groq-test-model", inference_status: "unverified"
      ))
      expect(a_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{environment_key}" }))
        .to have_been_made.once
      expect(a_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{organization_key}" }))
        .not_to have_been_made
    end

    it "prefers the organization credential over the environment credential" do
      create(:tool_integration, organization: organization, provider: "groq", credentials: { "api_key" => organization_key })

      expect(catalogue.call[:models]).to include(hash_including(provider_id: "groq", model_id: "groq-test-model"))
      expect(a_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{organization_key}" }))
        .to have_been_made.once
      expect(a_request(:get, groq_url).with(headers: { "Authorization" => "Bearer #{environment_key}" }))
        .not_to have_been_made
    end
  end

  context "with an Anthropic connection" do
    let!(:connection) { create(:tool_integration, organization: organization, provider: "anthropic", credentials: { api_key: "test-only-secret" }) }
    let(:anthropic_url) { "https://api.anthropic.com/v1/models" }

    before do
      stub_request(:get, anthropic_url).with(query: { limit: 100 }, headers: { "x-api-key" => "test-only-secret", "anthropic-version" => "2023-06-01" })
        .to_return(status: 200, body: { data: [ { id: "discovered-model", display_name: "Discovered model" } ], has_more: false }.to_json)
    end

    it "discovers organization-connected models without a hardcoded ID" do
      expect(catalogue.call[:models]).to include(hash_including(model_id: "discovered-model", provider_id: "anthropic", inference_status: "unverified"))
    end

    it "does not expose credentials" do
      expect(catalogue.call.to_json).not_to include("test-only-secret")
    end

    it "handles pagination" do
      stub_request(:get, anthropic_url).with(query: { limit: 100 }).to_return(status: 200,
        body: { data: [ { id: "first" } ], has_more: true, last_id: "first" }.to_json)
      stub_request(:get, anthropic_url).with(query: { limit: 100, after_id: "first" }).to_return(status: 200,
        body: { data: [ { id: "second" } ], has_more: false }.to_json)
      expect(catalogue.call[:models].pluck(:model_id)).to include("first", "second")
    end

    it "shows new models after refresh" do
      catalogue.call
      stub_request(:get, anthropic_url).with(query: { limit: 100 }).to_return(status: 200, body: { data: [ { id: "new-model" } ] }.to_json)
      expect(catalogue.call(refresh: true)[:models].pluck(:model_id)).to include("new-model")
    end

    it "filters disabled models and invalidates configuration changes" do
      catalogue.call
      connection.update!(config: { disabled_models: [ "discovered-model" ] })
      expect(catalogue.call[:models].pluck(:model_id)).not_to include("discovered-model")
    end

    it "filters retired models" do
      stub_request(:get, anthropic_url).with(query: { limit: 100 }).to_return(status: 200, body: { data: [ { id: "retired", lifecycle: "retired" } ] }.to_json)
      expect(catalogue.call[:models].pluck(:model_id)).not_to include("retired")
    end

    it "reports invalid credentials safely" do
      stub_request(:get, anthropic_url).with(query: { limit: 100 }).to_return(status: 401, body: "secret provider response")
      expect(catalogue.call[:providers]).to include(hash_including(error_code: "invalid_credentials"))
    end

    it "reports discovery timeout" do
      stub_request(:get, anthropic_url).with(query: { limit: 100 }).to_timeout
      expect(catalogue.call[:providers]).to include(hash_including(error_code: "provider_timeout"))
    end

    it "isolates other organizations" do
      other = create(:organization,
        owner: create(:user, email: "model-catalogue-other-owner@example.test"), slug: "model-catalogue-other-org")

      expect(described_class.new(other).call[:models].pluck(:provider_id)).not_to include("anthropic")
    end

    it "rejects disabled connections" do
      connection.update!(is_active: false)
      expect(catalogue.call[:providers]).to include(hash_including(provider_id: "anthropic", connection_status: "disabled"))
    end
  end

  context "with provider secrets in discovered and manual metadata" do
    let(:api_key) { "test-only-catalogue-api-key" }
    let(:header_secret) { "test-only-catalogue-header-secret" }
    let(:second_secret) { "test-only-catalogue-second-secret" }
    let(:groq_url) { "https://api.groq.com/openai/v1/models" }
    let!(:connection) do
      create(:tool_integration, organization: organization, provider: "groq", credentials: {
        "api_key" => api_key, "secret_headers" => { "X-Title" => header_secret, "Api-Key" => second_secret }
      }, config: {
        "models" => {
          "manual-model" => {
            "display_name" => "Manual model",
            "description" => "Contains #{header_secret}",
            "options" => { "nested" => { "key-#{second_secret}" => "hidden", "safe" => "kept" } }
          }
        }
      })
    end

    before do
      stub_request(:get, groq_url).to_return(status: 200, body: {
        data: [ {
          id: "discovered-model", display_name: "Discovered #{api_key}", description: "Header #{header_secret}",
          rate_limits: { "requests-#{second_secret}" => "hidden", "nested" => { "value" => api_key, "safe" => 10 } }
        } ]
      }.to_json)
    end

    it "redacts the API key and every secret header from live and manual catalogue output" do
      inventory = catalogue.owner_inventory(actor: organization.owner)
      serialized = inventory.to_json

      expect(inventory[:models].pluck(:model_id)).to include("discovered-model", "manual-model")
      expect(serialized).not_to include(api_key, header_secret, second_secret)
      expect(catalogue.call.to_json).not_to include(api_key, header_secret, second_secret)
    end

    it "redacts cached rows after discovery fails" do
      connection.update!(config: connection.config.merge("discovered_models" => [ {
        "id" => "cached-model", "description" => api_key,
        "rate_limits" => { "header-#{header_secret}" => second_secret, "safe" => 5 }
      } ]))
      stub_request(:get, groq_url).to_return(status: 500, body: "upstream failure")

      serialized = catalogue.owner_inventory(actor: organization.owner).to_json
      expect(serialized).to include("cached-model")
      expect(serialized).not_to include(api_key, header_secret, second_secret)
    end

    it "redacts cached rows for paused connections without making a discovery request" do
      connection.update!(is_active: false, config: connection.config.merge("discovered_models" => [ {
        "id" => "paused-model", "description" => header_secret,
        "rate_limits" => { "nested" => { "key-#{second_secret}" => api_key } }
      } ]))

      serialized = catalogue.owner_inventory(actor: organization.owner).to_json
      expect(serialized).to include("paused-model")
      expect(serialized).not_to include(api_key, header_secret, second_secret)
      expect(a_request(:get, groq_url)).not_to have_been_made
    end

    it "redacts cached custom-provider rows when discovery is disabled" do
      create(:tool_integration, organization: organization, provider: "custom-acme", credentials: {
        "api_key" => api_key, "secret_headers" => { "X-Title" => header_secret, "Api-Key" => second_secret }
      }, config: {
        "base_url" => "https://custom.example.test/v1", "auth_mode" => "none", "discovery_enabled" => false,
        "discovered_models" => [ { "id" => "custom-cached", "description" => api_key,
                                   "rate_limits" => { "nested" => { "key-#{header_secret}" => second_secret } } } ]
      })

      serialized = catalogue.owner_inventory(actor: organization.owner).to_json
      expect(serialized).to include("custom-cached")
      expect(serialized).not_to include(api_key)
      expect(a_request(:any, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
    end
  end

  context "with NVIDIA NIM" do
    let(:key) { "test-only-nvidia-key" }
    let(:url) { "https://integrate.api.nvidia.com/v1" }
    let(:model_id) { "nvidia/nemotron-3.5-lightning-30b-a3b" }
    let!(:connection) do
      create(:tool_integration, organization: organization, provider: "nvidia_nim", credentials: { "api_key" => key }, config: {
        "discovered_models" => [ { "id" => "stale-catalogue-model" } ],
        "last_verified_at" => 2.days.ago.iso8601,
        "models" => { model_id => { "display_name" => "Configurable NIM example" } }
      })
    end

    around do |example|
      original_env = ENV.to_hash
      ENV.delete("NVIDIA_NIM_API_KEY")
      ENV.delete("NVIDIA_NIM_BASE_URL")
      example.run
    ensure
      ENV.replace(original_env)
    end

    before do
      # Full inventory resolves credential fallbacks for every built-in provider.
      allow(Llm::ProviderRegistry).to receive(:credentials_key).and_return(nil)
    end

    it "registers the exact built-in endpoint, environment key, and default API family" do
      expect(Llm::ProviderRegistry::DEFINITIONS.fetch("nvidia_nim")).to include(
        name: "NVIDIA NIM", base_url: url, env_key: "NVIDIA_NIM_API_KEY", discovery: "none", manual_only: true,
        api_families: %w[chat_completions]
      )
      expect(Llm::ProviderRegistry.default_api_family("nvidia_nim")).to eq("chat_completions")
      expect(Llm::ProviderRegistry.name("nvidia_nim")).to eq("NVIDIA NIM")
      expect(Llm::ProviderRegistry.example_model_ids("nvidia_nim")).to eq(%w[
        nvidia/nemotron-3.5-lightning-30b-a3b nvidia/nemotron-3.5-bolt-e4b
        deepseek-ai/deepseek-v4-flash meta/llama-3.3-70b-instruct
      ])
    end

    it "rejects catalogue discovery explicitly without making a provider request" do
      expect { catalogue.verify_provider("nvidia_nim", key, connection) }
        .to raise_error(described_class::Error) { |error| expect(error.code).to eq("discovery_unsupported") }

      expect(Llm::ModelCatalogue::DISCOVERY_PROVIDERS).not_to include("nvidia_nim")
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "uses only manual rows and never claims catalogue discovery" do
      inventory = catalogue.owner_inventory(actor: organization.owner)
      provider = inventory[:providers].find { |entry| entry[:provider_id] == "nvidia_nim" }
      model = inventory[:models].find { |entry| entry[:provider_id] == "nvidia_nim" }

      expect(provider).to include(connection_status: "connected", readiness: "connected", inference_ready: false)
      expect(model).to include(model_id: model_id, api_family: "chat_completions", inference_status: "unverified",
                               last_discovered_at: nil, supports_tools: nil, supports_streaming: nil)
      expect(inventory[:models].pluck(:model_id)).not_to include("stale-catalogue-model")
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "ignores stale cached catalogue rows while paused" do
      connection.update!(is_active: false)
      inventory = catalogue.owner_inventory(actor: organization.owner)
      model = inventory[:models].find { |entry| entry[:provider_id] == "nvidia_nim" }

      expect(model).to include(availability_status: "disabled", last_discovered_at: nil)
      expect(inventory[:models].pluck(:model_id)).not_to include("stale-catalogue-model")
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "becomes inference ready only after recorded real inference" do
      selected = Llm::ProviderConnection.new(provider: "nvidia_nim", integration: connection, model: model_id)
      expect(Llm::InferenceTracker.record(selected, model_id, api_family: selected.api_family,
        fingerprint: selected.inference_fingerprint)).to be(true)

      inventory = catalogue.call(refresh: true)
      expect(inventory[:providers].find { |entry| entry[:provider_id] == "nvidia_nim" })
        .to include(readiness: "inference_ready", inference_ready: true)
      expect(inventory[:models].find { |entry| entry[:model_id] == model_id })
        .to include(inference_status: "verified", last_discovered_at: nil)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "does not treat a keyless manual row as connected or usable" do
      connection.update!(credentials: {})
      inventory = catalogue.owner_inventory(actor: organization.owner)

      expect(inventory[:providers].find { |entry| entry[:provider_id] == "nvidia_nim" })
        .to include(connection_status: "unavailable", error_code: "credentials_unavailable", readiness: "unavailable")
      expect(inventory[:models].find { |entry| entry[:model_id] == model_id })
        .to include(availability_status: "unavailable", inference_status: "unverified")
    end
  end

  context "with an OpenRouter catalogue" do
    let!(:connection) do
      create(:tool_integration, organization: organization, provider: "openrouter", credentials: { "api_key" => "test-only-openrouter-key" })
    end

    it "does not infer free-plan eligibility from zero pricing" do
      stub_request(:get, "https://openrouter.ai/api/v1/models").to_return(status: 200, body: {
        data: [
          { id: "zero-priced", pricing: { prompt: "0", completion: "0" } },
          { id: "explicit-free-tier", pricing: { prompt: "0", completion: "0" }, free_tier: true }
        ]
      }.to_json)

      models = catalogue.call[:models].to_h { |model| [ model[:model_id], model[:free_tier] ] }
      expect(models).to include("zero-priced" => nil, "explicit-free-tier" => true)
    end

    it "labels only complete reported zero token pricing independently of free-tier eligibility" do
      stub_request(:get, "https://openrouter.ai/api/v1/models").to_return(status: 200, body: {
        data: [
          { id: "zero-priced", pricing: { prompt: "0", completion: "0.0" } },
          { id: "paid", pricing: { prompt: "0.1", completion: "0" } },
          { id: "partial", pricing: { prompt: "0" } },
          { id: "malformed", pricing: { prompt: "not-a-price", completion: "0" } },
          { id: "named-free", pricing: nil }
        ]
      }.to_json)

      models = catalogue.call[:models].to_h { |model| [ model[:model_id], [ model[:zero_priced], model[:free_tier] ] ] }
      expect(models).to include("zero-priced" => [ true, nil ], "paid" => [ false, nil ],
        "partial" => [ nil, nil ], "malformed" => [ nil, nil ], "named-free" => [ nil, nil ])
    end
  end

  context "when inference outcomes are recorded" do
    let!(:connection) { create(:tool_integration, organization: organization, provider: "anthropic", credentials: { api_key: "readiness-secret" }) }
    let(:anthropic_url) { "https://api.anthropic.com/v1/models" }

    def stub_models(ids)
      stub_request(:get, anthropic_url).with(query: { limit: 100 })
        .to_return(status: 200, body: { data: ids.map { |id| { id: id } }, has_more: false }.to_json)
    end

    def anthropic_provider
      catalogue.call[:providers].find { |entry| entry[:provider_id] == "anthropic" }
    end

    def record_success(model_id)
      now = Time.current.iso8601
      connection.update_columns(config: connection.config.merge(
                                  "last_inference_succeeded_at" => now,
                                  "last_inference_attempt_at" => now,
                                  "last_inference_model_id" => model_id))
    end

    def record_fingerprinted_success(model_id)
      selected = Llm::ProviderConnection.new(provider: "anthropic", integration: connection, model: model_id)
      Llm::InferenceTracker.record(selected, model_id, api_family: selected.api_family,
        fingerprint: selected.inference_fingerprint)
    end

    def block_credits
      connection.update_columns(config: connection.config.merge(
                                  "last_inference_succeeded_at" => 2.minutes.ago.iso8601,
                                  "last_inference_attempt_at" => Time.current.iso8601,
                                  "last_inference_error_code" => "provider_credit_insufficient"))
    end

    it "reports connected when credentials work but no models were discovered" do
      stub_models([])
      expect(anthropic_provider).to include(readiness: "connected", inference_ready: false, billing_blocked: false)
    end

    it "reports catalogue_available after discovery without a real inference" do
      stub_models([ "discovered-model" ])
      expect(anthropic_provider).to include(readiness: "catalogue_available", inference_ready: false)
    end

    it "reports inference_ready after a recorded real request succeeded" do
      stub_models([ "discovered-model" ])
      record_success("discovered-model")
      expect(anthropic_provider).to include(readiness: "inference_ready", inference_ready: true)
    end

    it "marks only the model that actually served the successful request verified" do
      stub_models([ "discovered-model", "other-model" ])
      record_success("discovered-model")
      statuses = catalogue.call[:models].select { |m| m[:provider_id] == "anthropic" }.to_h { |m| [ m[:model_id], m[:inference_status] ] }
      expect(statuses).to eq("discovered-model" => "verified", "other-model" => "unverified")
    end

    it "keeps legacy non-fingerprinted success compatible" do
      stub_models([ "discovered-model" ])
      record_success("discovered-model")
      expect(catalogue.call[:models].find { |model| model[:provider_id] == "anthropic" })
        .to include(inference_status: "verified")
    end

    it "marks fingerprinted verification unverified after the credential changes" do
      stub_models([ "discovered-model" ])
      record_fingerprinted_success("discovered-model")
      expect(catalogue.call[:models].find { |model| model[:provider_id] == "anthropic" })
        .to include(inference_status: "verified")

      connection.update!(credentials: { "api_key" => "rotated-readiness-secret" })
      expect(catalogue.call(refresh: true)[:models].find { |model| model[:provider_id] == "anthropic" })
        .to include(inference_status: "unverified")
    end

    it "overrides a fingerprinted success when current discovery reports invalid credentials" do
      connection.update!(config: connection.config.merge("models" => { "discovered-model" => {} }))
      stub_models([ "discovered-model" ])
      record_fingerprinted_success("discovered-model")
      expect(anthropic_provider).to include(readiness: "inference_ready", inference_ready: true)

      stub_request(:get, anthropic_url).with(query: { limit: 100 })
        .to_return(status: 401, body: "secret provider response")
      inventory = catalogue.owner_inventory(actor: organization.owner, refresh: true)

      expect(connection.reload.config["models"]).to have_key("discovered-model")
      expect(catalogue.send(:manual_model_rows, connection.reload.config, [ "readiness-secret" ]).pluck("id"))
        .to eq([ "discovered-model" ])
      expect(inventory[:models].map { |model| [ model[:provider_id], model[:model_id] ] })
        .to include([ "anthropic", "discovered-model" ])
      expect(inventory[:providers].find { |entry| entry[:provider_id] == "anthropic" })
        .to include(readiness: "unavailable", inference_ready: false, error_code: "invalid_credentials")
      expect(inventory[:models].find { |model| model[:provider_id] == "anthropic" })
        .to include(inference_status: "failed", last_inference_error_code: "invalid_credentials")
    end

    it "reports billing blocked when the newest real request hit insufficient credits" do
      stub_models([ "discovered-model" ])
      block_credits
      expect(anthropic_provider).to include(readiness: "billing_blocked", billing_blocked: true, inference_ready: false)
    end

    it "marks discovered models billing blocked too" do
      stub_models([ "discovered-model" ])
      block_credits
      expect(catalogue.call[:models].find { |m| m[:provider_id] == "anthropic" }).to include(inference_status: "billing_blocked")
    end

    it "un-blocks billing once a newer success lands" do
      stub_models([ "discovered-model" ])
      record_success("discovered-model")
      expect(anthropic_provider).to include(readiness: "inference_ready", billing_blocked: false)
    end
  end

  context "with a Google connection" do
    let(:key) { "test-only-google-key" }
    let!(:connection) { create(:tool_integration, organization: organization, provider: "google", credentials: { api_key: key }) }

    it "uses only the native API-key header for discovery" do
      stub_request(:get, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100").with do |request|
        expect(request.headers["X-Goog-Api-Key"]).to eq(key)
        expect(request.headers).not_to have_key("Authorization")
        expect(request.uri.query_values).to include("pageSize" => "100")
        true
      end.to_return(status: 200, body: {
        models: [ { name: "models/gemini-test", displayName: "Gemini Test", inputTokenLimit: 8192 } ]
      }.to_json)

      expect(catalogue.call[:models]).to include(hash_including(
        provider_id: "google", model_id: "gemini-test", context_window: 8192, inference_status: "unverified"
      ))
    end
  end

  context "with an OpenCode connection" do
    let!(:connection) do
      create(:tool_integration, organization: organization, provider: "opencode", credentials: { api_key: "test-only-opencode-key" })
    end

    it "marks official external-client-restricted free chat models without restricting OpenCode Go rows" do
      stub_request(:get, "https://opencode.ai/zen/v1/models").to_return(status: 200, body: {
        data: [ { id: "big-pickle" }, { id: "opencode-go/big-pickle", provider: "opencode-go" } ]
      }.to_json)

      models = catalogue.owner_inventory(actor: organization.owner)[:models]
        .select { |model| model[:provider_id] == "opencode" }.to_h { |model| [ model[:model_id], model[:availability_status] ] }
      expect(models).to eq("big-pickle" => "access_restricted", "opencode-go/big-pickle" => "available")
    end
  end

  it "marks manual models configuration invalid when their custom endpoint is prohibited" do
    create(:tool_integration, organization: organization, provider: "custom-acme", config: {
      "base_url" => "https://10.0.0.1/v1", "auth_mode" => "none",
      "models" => { "manual-model" => { "api_family" => "chat_completions" } }
    })

    model = catalogue.owner_inventory(actor: organization.owner)[:models].find { |entry| entry[:model_id] == "manual-model" }
    expect(model[:availability_status]).to eq("configuration_invalid")
    expect(model[:inference_status]).to eq("unverified")
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/LetSetup, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
