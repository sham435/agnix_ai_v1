# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe "Settings provider architecture", type: :request do
  around do |example|
    original_env = ENV.to_hash
    ENV.delete("GROQ_BASE_URL")
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    ENV.replace(original_env)
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:provider_id) { "custom-acme" }
  let(:base_url) { "https://custom.example.test/v1" }
  let(:api_key) { "test-only-custom-api-key-9f2c" }
  let(:secret_header) { "test-only-secret-header-7d4a" }
  let(:model_id) { "responses-model" }

  before do
    Rails.cache.clear
    create(:membership, user: user, organization: organization, role: "owner")
    api_login(user)
    # Endpoint/SSRF policy is covered in provider_endpoint_spec; isolate settings mutations from DNS.
    allow(Llm::ProviderEndpoint).to receive(:enforce_destination!)
    stub_request(:get, %r{\Ahttp://127\.0\.0\.1:(?:8080|8910)/v1/models})
      .to_return(status: 200, body: { data: [] }.to_json)
  end

  def custom_connection_params(overrides = {})
    {
      name: "Acme test provider", base_url: base_url, auth_mode: "bearer", api_key: api_key,
      discovery_enabled: false, headers: { "HTTP-Referer" => "https://app.example.test" },
      secret_headers: { "X-Title" => secret_header }
    }.merge(overrides)
  end

  def manual_model_params(overrides = {})
    {
      display_name: "Acme Responses", description: "Test-only manual model", api_family: "responses",
      supports_tools: "true", supports_streaming: "true", supports_vision: "false", supports_json_mode: "true",
      supports_reasoning: "true", supports_parallel_tool_calls: "false", context_window: "32768",
      max_output_tokens: "128", free_tier: "true", access_restricted: "false", reasoning_parameters: "effort",
      supported_parameters: %w[input temperature max_output_tokens tools top_p seed text store],
      options: { temperature: 0.2, max_output_tokens: 64, store: false }.to_json,
      rate_limits: { requests_per_minute: 60 }.to_json
    }.merge(overrides)
  end

  def save_custom(overrides = {})
    post settings_integrations_custom_path,
         params: { provider_id: provider_id, custom_connection: custom_connection_params(overrides) },
         headers: api_headers
    response
  end

  def save_manual_model(overrides = {})
    post settings_integrations_manual_model_path,
         params: { provider_id: provider_id, model_id: model_id, model_config: manual_model_params(overrides) },
         headers: api_headers
    response
  end

  def update_manual_model(params)
    post settings_integrations_manual_model_path,
         params: { provider_id: provider_id, model_id: model_id, model_config: params }, headers: api_headers
    response
  end

  def verify_custom
    stub_request(:post, "#{base_url}/responses").to_return(status: 200, body: {
      status: "completed", output: [ { type: "message", content: [ { type: "output_text", text: "OK" } ] } ],
      usage: { output_tokens: 2 }
    }.to_json)
    post settings_integrations_verify_model_path,
         params: { provider_id: provider_id, model_id: model_id }, headers: api_headers
    response
  end

  def response_json
    JSON.parse(response.body)
  end

  def provider_entry(json = response_json)
    json.fetch("providers").find { |entry| entry["provider_id"] == provider_id }
  end

  def model_entry(json = response_json)
    json.fetch("models").find { |entry| entry["provider_id"] == provider_id && entry["model_id"] == model_id }
  end

  def raw_credentials(connection)
    quoted_id = ToolIntegration.connection.quote(connection.id)
    ToolIntegration.connection
      .select_value("SELECT credentials::text FROM tool_integrations WHERE id = #{quoted_id}").to_s
  end

  describe "custom connections and manual models" do
    it "registers capabilities, limits, and options without exposing encrypted secret headers" do
      expect(save_custom).to have_http_status(:ok)
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.is_active?).to be(true)
      expect(connection.decrypted_credentials).to include(
        "api_key" => api_key, "secret_headers" => { "X-Title" => secret_header }
      )
      expect(raw_credentials(connection)).not_to include(api_key, secret_header)

      expect(save_manual_model).to have_http_status(:ok)
      metadata = connection.reload.config.fetch("models").fetch(model_id)
      expect(metadata).to include(
        "api_family" => "responses", "supports_tools" => true, "supports_streaming" => true,
        "supports_vision" => false, "supports_json_mode" => true, "supports_reasoning" => true,
        "supports_parallel_tool_calls" => false, "context_window" => 32_768, "max_output_tokens" => 128,
        "options" => { "temperature" => 0.2, "max_output_tokens" => 64, "store" => false },
        "rate_limits" => { "requests_per_minute" => 60 }
      )
      expect(metadata["supported_parameters"]).to eq(
        %w[input temperature max_output_tokens tools top_p seed text store]
      )
      expect(metadata["reasoning_parameters"]).to eq([ "effort" ])
      expect(model_entry).to include("inference_status" => "unverified", "api_family" => "responses")
      expect(model_entry["option_names"]).to contain_exactly("temperature", "max_output_tokens", "store")
      expect(provider_entry).to include("inference_ready" => false, "readiness" => "catalogue_available")
      expect(response.body).not_to include(api_key, secret_header)

      get settings_integrations_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(api_key, secret_header)
      expect(Llm::ModelCatalogue.new(organization).call.to_json).not_to include(api_key, secret_header)
      expect(a_request(:any, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
    end

    it "stores documented credential headers only in encrypted credentials" do
      expect(save_custom(auth_mode: "x-api-key", secret_headers: { "X-Goog-Api-Key" => secret_header }))
        .to have_http_status(:ok)
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)

      expect(connection.decrypted_credentials).to include("secret_headers" => { "X-Goog-Api-Key" => secret_header })
      expect(raw_credentials(connection)).not_to include(api_key, secret_header)
      expect(response.body).not_to include(api_key, secret_header)
      selected = Llm::ProviderConnection.new(provider: provider_id, integration: connection, model: model_id)
      expect(selected.headers).to include("X-Api-Key" => api_key, "X-Goog-Api-Key" => secret_header)
      expect(selected.headers).not_to have_key("Authorization")
    end

    it "preserves a stored custom API key and secret header when replacement fields are blank" do
      save_custom
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      original_credentials = connection.reload.decrypted_credentials

      expect(save_custom(api_key: "   ", secret_headers: { "X-Title" => "" })).to have_http_status(:ok)

      expect(connection.reload.decrypted_credentials).to eq(original_credentials)
      expect(response.body).not_to include(api_key, secret_header)
      expect(a_request(:any, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
    end

    it "preserves a stored built-in API key when the replacement is blank" do
      definition = Llm::ProviderRegistry::DEFINITIONS.fetch("groq")
      stored_key = "test-only-stored-groq-key"
      create(:tool_integration, organization: organization, provider: "groq",
                                credentials: { "api_key" => stored_key })
      stub_request(:get, "#{definition[:base_url]}/models")
        .to_return(status: 200, body: { data: [ { id: "groq-test-model" } ] }.to_json)

      post settings_integrations_keys_path, params: { provider_id: "groq", api_key: "   " }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(ToolIntegration.find_by!(organization: organization, provider: "groq").api_key).to eq(stored_key)
      expect(a_request(:get, "#{definition[:base_url]}/models")
        .with(headers: { "Authorization" => "Bearer #{stored_key}" })).to have_been_made.twice
      expect(a_request(:post, %r{\Ahttps://api\.groq\.com})).not_to have_been_made
    end
  end

  describe "built-in manual models" do
    let(:groq_key) { "test-only-built-in-groq-key" }
    let(:groq_model_id) { "groq-manual-model" }
    let!(:groq_connection) do
      create(:tool_integration, organization: organization, provider: "groq", credentials: { "api_key" => groq_key })
    end

    before do
      definition = Llm::ProviderRegistry::DEFINITIONS.fetch("groq")
      stub_request(:get, "#{definition[:base_url]}/models")
        .to_return(status: 200, body: { data: [ { id: "discovered-groq-model" } ] }.to_json)
    end

    it "saves per-model metadata for a built-in provider with a persisted connection" do
      post settings_integrations_manual_model_path,
           params: { provider_id: "groq", model_id: groq_model_id,
                     model_config: manual_model_params(api_family: "chat_completions",
                       supported_parameters: %w[messages temperature max_tokens tools top_p seed],
                       options: { temperature: 0.2, seed: 1 }.to_json) }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(groq_connection.reload.config.fetch("models").fetch(groq_model_id)).to include(
        "api_family" => "chat_completions", "supports_tools" => true, "supports_streaming" => true,
        "context_window" => 32_768, "max_output_tokens" => 128
      )
      expect(response_json.fetch("models")).to include(hash_including(
        "provider_id" => "groq", "model_id" => groq_model_id,
        "inference_status" => "unverified", "api_family" => "chat_completions"
      ))
      expect(response.body).not_to include(groq_key)
    end

    it "rejects an API family the built-in provider does not support" do
      post settings_integrations_manual_model_path,
           params: { provider_id: "groq", model_id: groq_model_id,
                     model_config: manual_model_params(api_family: "responses") }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("invalid_model_settings")
      expect(groq_connection.reload.config.fetch("models", {})).not_to have_key(groq_model_id)
    end
  end

  describe "NVIDIA NIM manual-only provider" do
    let(:provider_id) { "nvidia_nim" }
    let(:nvidia_key) { "test-only-nvidia-nim-key-4c8e" }
    let(:model_id) { "nvidia/nemotron-3.5-lightning-30b-a3b" }
    let(:nvidia_url) { "https://integrate.api.nvidia.com/v1" }

    before do
      ENV.delete("NVIDIA_NIM_API_KEY")
      ENV.delete("NVIDIA_NIM_BASE_URL")
      # Full inventory resolves credential fallbacks for every built-in provider.
      allow(Llm::ProviderRegistry).to receive(:credentials_key).and_return(nil)
    end

    def save_nvidia_key(value = nvidia_key)
      params = { provider_id: provider_id }
      params[:api_key] = value unless value == :omitted
      post settings_integrations_keys_path, params: params, headers: api_headers
      response
    end

    def save_nvidia_model(params = {})
      post settings_integrations_manual_model_path,
           params: { provider_id: provider_id, model_id: model_id,
                     model_config: { display_name: "Configured NIM model", api_family: "chat_completions" }.merge(params) },
           headers: api_headers
      response
    end

    it "saves an encrypted key without discovery, inference, or fabricated catalogue state" do
      create(:tool_integration, organization: organization, provider: provider_id,
                                credentials: { "api_key" => "test-only-old-nvidia-key" }, config: {
                                  "discovered_models" => [ { "id" => "stale-model" } ],
                                  "last_verified_at" => "2026-01-01T00:00:00Z",
                                  "last_verification_attempt_at" => "2026-01-01T00:00:00Z",
                                  "last_verification_error" => "invalid_credentials"
                                })

      expect(save_nvidia_key).to have_http_status(:ok)

      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.is_active?).to be(true)
      expect(connection.api_key).to eq(nvidia_key)
      expect(connection.config).not_to include("discovered_models", "last_verified_at",
        "last_verification_attempt_at", "last_verification_error")
      expect(raw_credentials(connection)).not_to include(nvidia_key)
      expect(response.body).not_to include(nvidia_key)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    [ [ "omitted", :omitted ], [ "blank", "   " ] ].each do |label, value|
      it "preserves the existing encrypted key when the replacement is #{label}" do
        create(:tool_integration, organization: organization, provider: provider_id,
                                  credentials: { "api_key" => nvidia_key })

        expect(save_nvidia_key(value)).to have_http_status(:ok)

        expect(ToolIntegration.find_by!(organization: organization, provider: provider_id).api_key).to eq(nvidia_key)
        expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
      end
    end

    it "uses an existing environment key for a blank save without copying it into encrypted credentials" do
      ENV["NVIDIA_NIM_API_KEY"] = nvidia_key

      expect(save_nvidia_key(:omitted)).to have_http_status(:ok)

      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.is_active?).to be(true)
      expect(connection.api_key).to be_nil
      resolved = Llm::ProviderConnection.resolve(organization: organization, provider: provider_id, model: model_id)
      expect(resolved.api_key).to eq(nvidia_key)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "keeps the key form visible with configurable examples and honest manual-only labels" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      inventory = response_json

      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(aria-label="NVIDIA NIM API key"), "Save key",
        "Official catalogue discovery is unavailable", "Verify first to set default",
        "nvidia/nemotron-3.5-lightning-30b-a3b", "nvidia/nemotron-3.5-bolt-e4b",
        "deepseek-ai/deepseek-v4-flash", "meta/llama-3.3-70b-instruct",
        "not claims of access, capabilities, or limits")
      expect(response.body).not_to include("Catalogue checked", "Catalogue available", "Discovered ")
      expect(model_entry(inventory)).to include("api_family" => "chat_completions", "inference_status" => "unverified",
        "supports_tools" => nil, "supports_streaming" => nil, "context_window" => nil,
        "max_output_tokens" => nil, "free_tier" => nil)
      expect(model_entry(inventory)["last_discovered_at"]).to be_nil
      expect(provider_entry(inventory)).to include("readiness" => "connected", "inference_ready" => false,
        "last_verified_at" => nil, "last_catalogue_verified_at" => nil)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "uses the exact registry label in the read-only member summary" do
      create(:tool_integration, organization: organization, provider: provider_id,
                                credentials: { "api_key" => nvidia_key })
      member = create(:user)
      create(:membership, user: member, organization: organization, role: "member")
      api_login(member)

      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("NVIDIA NIM")
      expect(response.body).not_to include("Nvidia_nim", "Nvidia Nim")
      expect(response.body).not_to include("Save key", nvidia_key)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "registers a model without claiming capabilities, pricing eligibility, or limits" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)

      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.config.fetch("models").fetch(model_id)).to eq(
        "display_name" => "Configured NIM model", "api_family" => "chat_completions"
      )
      expect(model_entry).to include("availability_status" => "available", "manageable" => true,
        "supported_parameters" => nil, "rate_limits" => {}, "option_names" => [])
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "leaves manual-only connection metadata unchanged on refresh without any provider request" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      original_config = connection.config.deep_dup

      post settings_integrations_refresh_path, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(connection.reload.config).to eq(original_config)
      expect(provider_entry).to include("readiness" => "connected", "inference_ready" => false)
      expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "verifies with Rails credentials when organization and environment keys are absent" do
      allow(Llm::ProviderRegistry).to receive(:credentials_key).with("nvidia_nim").and_return(nvidia_key)
      create(:tool_integration, organization: organization, provider: provider_id, credentials: {}, config: {
        "models" => { model_id => { "api_family" => "chat_completions" } }
      })
      stub_request(:post, "#{nvidia_url}/chat/completions").to_return(status: 200, body: {
        choices: [ { message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ]
      }.to_json)

      expect(save_nvidia_model).to have_http_status(:ok)
      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(a_request(:post, "#{nvidia_url}/chat/completions")
        .with(headers: { "Authorization" => "Bearer #{nvidia_key}" })).to have_been_made.once
      expect(model_entry).to include("inference_status" => "verified")
      expect(ToolIntegration.find_by!(organization: organization, provider: provider_id).api_key).to be_nil
    end

    it "requires explicit real inference before accepting an organization default" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      url = "#{nvidia_url}/chat/completions"
      stub_request(:post, url).to_return(status: 200, body: {
        choices: [ { message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ],
        usage: { completion_tokens: 2 }
      }.to_json)

      post settings_integrations_default_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("inference_unverified")
      expect(organization.reload.settings["default_model"]).to be_nil
      expect(a_request(:post, url)).not_to have_been_made

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(a_request(:post, url).with(headers: { "Authorization" => "Bearer #{nvidia_key}" }) do |request|
        body = JSON.parse(request.body)
        expect(body).to include("model" => model_id, "messages" => [ { "role" => "user", "content" => "Reply with OK." } ])
        expect(body).not_to have_key("tools")
        true
      end).to have_been_made.once
      expect(model_entry).to include("inference_status" => "verified")
      expect(provider_entry).to include("connection_status" => "connected", "readiness" => "inference_ready",
        "inference_ready" => true)

      post settings_integrations_default_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(organization.reload.settings["default_model"]).to eq("provider_id" => provider_id, "model_id" => model_id)
      expect(a_request(:post, url)).to have_been_made.once
      expect(a_request(:get, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
    end

    it "records an empty verification reply as failed rather than successful" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      stub_request(:post, "#{nvidia_url}/chat/completions").to_return(status: 200, body: {
        choices: [ { message: { role: "assistant", content: "", reasoning_content: "Reasoning only" },
                     finish_reason: "stop" } ]
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("invalid_provider_response")
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      verification = connection.config.fetch("inference_verifications").fetch(model_id)
      expect(verification["error_code"]).to eq("invalid_provider_response")
      expect(verification["succeeded_at"]).to be_nil
      expect(connection.config["last_inference_succeeded_at"]).to be_nil
    end

    it "accepts a tool-call-only reply as proof of real inference" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      stub_request(:post, "#{nvidia_url}/chat/completions").to_return(status: 200, body: {
        choices: [ { message: { role: "assistant", content: nil, tool_calls: [
          { id: "call-nim-verify", type: "function", function: { name: "noop", arguments: "{}" } }
        ] }, finish_reason: "tool_calls" } ]
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(model_entry).to include("inference_status" => "verified")
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      verification = connection.config.fetch("inference_verifications").fetch(model_id)
      expect(verification["succeeded_at"]).to be_present
      expect(verification["error_code"]).to be_nil
    end

    it "returns sanitized typed inference errors without claiming verification" do
      expect(save_nvidia_key).to have_http_status(:ok)
      expect(save_nvidia_model).to have_http_status(:ok)
      raw_marker = "RAW-NVIDIA-ERROR-DO-NOT-LEAK"
      stub_request(:post, "#{nvidia_url}/chat/completions").to_return(status: 402, body: {
        error: { type: "insufficient_quota", message: raw_marker, api_key: nvidia_key }
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("provider_credit_insufficient")
      expect(response.body).not_to include(raw_marker, nvidia_key, nvidia_url)
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.config.fetch("inference_verifications").fetch(model_id)["error_code"])
        .to eq("provider_credit_insufficient")
      provider = Llm::ModelCatalogue.new(organization).call[:providers].find { |entry| entry[:provider_id] == provider_id }
      expect(provider).to include(connection_status: "connected", inference_ready: false, readiness: "billing_blocked")
    end
  end

  describe "manual model metadata updates" do
    before do
      save_custom
    end

    it "preserves omitted metadata, including access restrictions" do
      expect(save_manual_model(access_restricted: "true", free_tier: "true")).to have_http_status(:ok)
      expect(update_manual_model(display_name: "Renamed Responses")).to have_http_status(:ok)

      metadata = ToolIntegration.find_by!(organization: organization, provider: provider_id)
        .config.fetch("models").fetch(model_id)
      expect(metadata).to include("display_name" => "Renamed Responses", "access_restricted" => true,
        "free_tier" => true, "supports_tools" => true, "context_window" => 32_768)
      expect(model_entry).to include("access_restricted" => true, "availability_status" => "access_restricted")
    end

    it "clears explicitly blank metadata overrides without fabricating defaults" do
      expect(save_manual_model(access_restricted: "true", free_tier: "true")).to have_http_status(:ok)
      blanks = {
        display_name: "", description: "", supports_tools: "", supports_streaming: "", supports_vision: "",
        supports_json_mode: "", supports_reasoning: "", supports_parallel_tool_calls: "",
        context_window: "", max_output_tokens: "", free_tier: "", access_restricted: "",
        reasoning_parameters: "", supported_parameters: "", options: "", rate_limits: ""
      }
      expect(update_manual_model(blanks)).to have_http_status(:ok)

      metadata = ToolIntegration.find_by!(organization: organization, provider: provider_id)
        .config.fetch("models").fetch(model_id)
      expect(metadata).to eq("api_family" => "responses")
      expect(model_entry).to include("access_restricted" => false, "free_tier" => nil,
        "supports_tools" => nil, "context_window" => nil, "rate_limits" => {}, "option_names" => [])
    end
  end

  describe "legacy OpenAI keys routed through OpenRouter" do
    let(:legacy_key) { "sk-or-v1-test-only-legacy" }
    let(:legacy_model) { "vendor/model" }

    before do
      ENV.delete("OPENAI_BASE_URL")
      ENV["OPENROUTER_BASE_URL"] = "https://openrouter.ai/api/v1"
      stub_request(:get, "https://openrouter.ai/api/v1/models").to_return(status: 200, body: {
        data: [ { id: legacy_model, name: "Legacy routed model" } ]
      }.to_json)
    end

    it "uses OpenRouter consistently during discovery while preserving the stored OpenAI row" do
      connection = create(:tool_integration, organization: organization, provider: "openai",
        credentials: { "api_key" => legacy_key })

      post settings_integrations_refresh_path, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(a_request(:get, "https://openrouter.ai/api/v1/models")
        .with(headers: { "Authorization" => "Bearer #{legacy_key}" })).to have_been_made.at_least_once
      expect(a_request(:get, %r{\Ahttps://api\.openai\.com})).not_to have_been_made
      expect(connection.reload.provider).to eq("openai")
      expect(connection.config["discovered_models"].pluck("id")).to include(legacy_model)
    end

    it "uses OpenRouter for explicit verification and records inference on the legacy row" do
      connection = create(:tool_integration, organization: organization, provider: "openai",
        credentials: { "api_key" => legacy_key })
      stub_request(:post, "https://openrouter.ai/api/v1/chat/completions").to_return(status: 200, body: {
        choices: [ { message: { role: "assistant", content: "OK" }, finish_reason: "stop" } ],
        usage: { output_tokens: 2 }
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: "openai", model_id: legacy_model }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(a_request(:post, "https://openrouter.ai/api/v1/chat/completions")
        .with(headers: { "Authorization" => "Bearer #{legacy_key}" })).to have_been_made.once
      expect(a_request(:post, %r{\Ahttps://api\.openai\.com})).not_to have_been_made
      verification = connection.reload.config.fetch("inference_verifications").fetch(legacy_model)
      expect(verification).to include("error_code" => nil)
      expect(verification["succeeded_at"]).to be_present
      discovered = response_json.fetch("models").find do |entry|
        entry["provider_id"] == "openai" && entry["model_id"] == legacy_model
      end
      expect(discovered).to include("inference_status" => "verified")
    end
  end

  describe "discovery versus inference verification" do
    it "discovers a catalogue without sending inference or marking it ready" do
      stub_request(:get, "#{base_url}/models").to_return(status: 200, body: {
        data: [ { id: "discovered-model", display_name: "Discovered test model" } ]
      }.to_json)

      expect(save_custom(discovery_enabled: true)).to have_http_status(:ok)

      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      expect(connection.config["last_verified_at"]).to be_present
      expect(connection.config["inference_verifications"]).to be_blank
      expect(connection.config["last_inference_succeeded_at"]).to be_nil
      discovered = response_json.fetch("models").find { |entry| entry["model_id"] == "discovered-model" }
      expect(discovered).to include("inference_status" => "unverified")
      expect(provider_entry).to include("inference_ready" => false, "readiness" => "catalogue_available")
      expect(a_request(:get, "#{base_url}/models")).to have_been_made.twice
      expect(a_request(:post, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
    end

    it "records successful real inference only after the explicit Verify Model action" do
      save_custom
      save_manual_model
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      url = "#{base_url}/responses"
      stub_request(:post, url).to_return(status: 200, body: {
        status: "completed", output: [ { type: "message", content: [ { type: "output_text", text: "OK" } ] } ],
        usage: { output_tokens: 2 }
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(a_request(:post, url).with(headers: {
        "Authorization" => "Bearer #{api_key}", "HTTP-Referer" => "https://app.example.test", "X-Title" => secret_header
      }) do |request|
        body = JSON.parse(request.body)
        expect(body).to include("model" => model_id, "max_output_tokens" => 16,
                                "input" => [ { "role" => "user", "content" => "Reply with OK." } ])
        expect(body).not_to have_key("messages")
        true
      end).to have_been_made.once
      expect(a_request(:get, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
      verification = connection.reload.config.fetch("inference_verifications").fetch(model_id)
      expect(verification).to include("api_family" => "responses", "error_code" => nil)
      expect(verification["succeeded_at"]).to be_present
      expect(verification["configuration_fingerprint"]).to be_present
      expect(connection.config["last_inference_model_id"]).to eq(model_id)
      expect(model_entry).to include("inference_status" => "verified")
      expect(provider_entry).to include("inference_ready" => true, "readiness" => "inference_ready")
    end

    it "returns a sanitized typed verification error and records the failed inference" do
      save_custom
      save_manual_model
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      raw_marker = "RAW-VERIFY-BODY-DO-NOT-LEAK"
      stub_request(:post, "#{base_url}/responses").to_return(status: 402, body: {
        error: { type: "insufficient_quota", message: raw_marker, endpoint: "#{base_url}/responses", key: api_key }
      }.to_json)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("provider_credit_insufficient")
      expect(response.body).not_to include(raw_marker, api_key, secret_header, base_url)
      verification = connection.reload.config.fetch("inference_verifications").fetch(model_id)
      expect(verification["error_code"]).to eq("provider_credit_insufficient")
      expect(verification["succeeded_at"]).to be_nil
    end

    {
      "API key" => { api_key: "test-only-rotated-custom-key" },
      "secret header" => { secret_headers: { "X-Title" => "test-only-rotated-secret-header" } },
      "endpoint" => { base_url: "https://other.example.test/v1" }
    }.each do |label, overrides|
      it "clears inference verification when the #{label} changes" do
        save_custom
        save_manual_model
        expect(verify_custom).to have_http_status(:ok)
        connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
        expect(connection.config.fetch("inference_verifications")).to have_key(model_id)

        expect(save_custom(overrides)).to have_http_status(:ok)

        expect(connection.reload.config.fetch("inference_verifications")).to be_blank
        expect(connection.config["last_inference_succeeded_at"]).to be_nil
        expect(connection.config["last_inference_model_id"]).to be_nil
        expect(connection.config["last_inference_configuration_fingerprint"]).to be_nil
      end
    end

    it "clears only the edited model verification when its capabilities or options change" do
      save_custom
      save_manual_model
      expect(verify_custom).to have_http_status(:ok)
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)

      expect(save_manual_model(options: { temperature: 0.3, max_output_tokens: 64, store: false }.to_json,
                               supports_streaming: "false")).to have_http_status(:ok)

      expect(connection.reload.config.fetch("inference_verifications")).to be_blank
      expect(connection.config["models"].fetch(model_id)).to include("supports_streaming" => false,
        "options" => { "temperature" => 0.3, "max_output_tokens" => 64, "store" => false })
    end

    it "rejects verification while the connection is inactive without sending inference" do
      save_custom
      save_manual_model
      connection = ToolIntegration.find_by!(organization: organization, provider: provider_id)
      connection.update!(is_active: false)

      post settings_integrations_verify_model_path,
           params: { provider_id: provider_id, model_id: model_id }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response_json["error_code"]).to eq("connection_inactive")
      expect(connection.reload.config["inference_verifications"]).to be_blank
      expect(a_request(:post, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
    end
  end

  describe "header validation" do
    {
      "protected header" => { headers: { "Authorization" => "must-not-send" } },
      "public API-key header" => { headers: { "Api-Key" => "must-not-send" } },
      "public Google API-key header" => { headers: { "X-Goog-Api-Key" => "must-not-send" } },
      "duplicate active authentication header" => { secret_headers: { "Authorization" => "must-not-send" } },
      "CRLF header value" => { headers: { "X-Title" => "safe\r\nX-Injected: true" } },
      "CRLF secret header" => { secret_headers: { "X-Title" => "safe\r\nX-Injected: true" } }
    }.each do |label, overrides|
      it "rejects a #{label}" do
        save_custom(overrides)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response_json["error_code"]).to eq("configuration_invalid")
        expect(response.body).not_to include("X-Injected", "must-not-send")
        expect(ToolIntegration.find_by(organization: organization, provider: provider_id)).to be_nil
        expect(a_request(:any, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
      end
    end
  end

  describe "owner-only mutations" do
    let!(:owned_connection) do
      create(:tool_integration, organization: organization, provider: provider_id, name: "Owned custom provider",
                                credentials: { "api_key" => api_key }, config: {
                                  "base_url" => base_url, "auth_mode" => "bearer", "discovery_enabled" => false,
                                  "models" => { model_id => { "api_family" => "responses" } }
                                })
    end

    {
      "custom connection save" => [ :settings_integrations_custom_path, :custom ],
      "manual model save" => [ :settings_integrations_manual_model_path, :model ],
      "model verification" => [ :settings_integrations_verify_model_path, :verify ]
    }.each do |label, (path_name, action)|
      it "rejects a non-owner #{label}" do
        member = create(:user)
        create(:membership, user: member, organization: organization, role: "member")
        api_login(member)
        mutation_params = case action
        when :custom then { provider_id: provider_id, custom_connection: custom_connection_params }
        when :model then { provider_id: provider_id, model_id: model_id,
                                             model_config: manual_model_params }
        else { provider_id: provider_id, model_id: model_id }
        end

        expect do
          post public_send(path_name), params: mutation_params, headers: api_headers
        end.not_to change { [ owned_connection.reload.config, owned_connection.reload.decrypted_credentials ] }

        expect(response).to have_http_status(:forbidden)
        expect(response_json["error_code"]).to eq("owner_required")
        expect(a_request(:any, %r{\Ahttps://custom\.example\.test})).not_to have_been_made
      end
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
