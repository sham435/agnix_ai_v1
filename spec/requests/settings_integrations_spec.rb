# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength,
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleDescribes

# Settings › Integrations: model provider management is owner-only. Keys are
# verified against the provider's live catalogue before being stored encrypted,
# connections and individual models can be toggled, and the organization default
# is validated through the catalogue. Secrets are never rendered.
RSpec.describe "Settings integrations", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }

  before do
    create(:membership, user: user, organization: organization, role: "owner")
    api_login(user)
    stub_request(:get, %r{\Ahttp://(127\.0\.0\.1|localhost):8080/v1/models})
      .to_return(status: 200, body: { data: [ { id: "gguf", meta: { n_ctx: 32768 } } ] }.to_json)
  end

  def html_form_headers
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" }
  end

  def stub_anthropic_models(status: 200)
    stub_request(:get, %r{\Ahttps://api\.anthropic\.com/v1/models})
      .to_return(status: status, body: { data: [ { id: "claude-test", display_name: "Claude Test" } ], has_more: false }.to_json)
  end

  def raw_credentials(id)
    ToolIntegration.connection
      .select_value("SELECT credentials::text FROM tool_integrations WHERE id = '#{id}'")
      .to_s
  end

  describe "GET /settings/integrations" do
    it "shows the owner every provider with masked credentials and controls" do
      stub_anthropic_models
      create(:tool_integration, organization: organization, provider: "anthropic",
                                credentials: { "api_key" => "sk-ant-secret-9000" })

      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      Llm::ProviderSettings::PROVIDERS.each do |provider|
        expect(response.body).to include(%(id="provider-row-#{provider}"))
      end
      expect(response.body).to include("Key configured (hidden)")
      expect(response.body).to include("Refresh catalogue")
      expect(response.body).to include("Save key")
      expect(response.body).to include("Claude Test")
      expect(response.body).not_to include("sk-ant-secret-9000")
    end

    it "labels reported zero token pricing separately from free-plan eligibility and preserves it in cached rows" do
      stub_request(:get, "https://openrouter.ai/api/v1/models").to_return(status: 200, body: {
        data: [
          { id: "zero-priced", display_name: "Zero Priced", pricing: { prompt: "0", completion: "0" } },
          { id: "free-tier", display_name: "Free Tier", pricing: { prompt: "0", completion: "0" }, free_tier: true }
        ]
      }.to_json)
      connection = create(:tool_integration, organization: organization, provider: "openrouter",
        credentials: { "api_key" => "test-only-openrouter-key" })

      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      model_rows = document.css("#provider-row-openrouter li")
      zero_row = model_rows.find { |entry| entry.text.include?("Zero Priced") }
      free_row = model_rows.find { |entry| entry.text.include?("Free Tier") }
      zero_badges = zero_row.css("span").map(&:text)
      free_badges = free_row.css("span").map(&:text)
      expect(zero_badges).to include("Provider reports zero token pricing")
      expect(zero_badges).not_to include("Free-plan eligible")
      expect(free_badges).to include("Provider reports zero token pricing", "Free-plan eligible")

      post settings_integrations_refresh_path, headers: html_form_headers
      expect(response).to redirect_to(settings_integrations_path)
      cached = connection.reload.config.fetch("discovered_models").to_h { |row| [ row["id"], row["zero_priced"] ] }
      expect(cached).to include("zero-priced" => true, "free-tier" => true)

      connection.update!(is_active: false)
      get settings_integrations_path
      expect(response.body).to include("Provider reports zero token pricing")
    end

    it "shows a member a read-only summary without management controls" do
      member = create(:user)
      create(:membership, user: member, organization: organization)
      api_login(member)

      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Only the organization owner")
      expect(response.body).not_to include("Save key")
      expect(response.body).not_to include("Refresh catalogue")
    end

    it "gives every marketplace plugin a connect action when nothing is configured" do
      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      Tools::Catalog.keys.each do |key|
        expect(response.body).to include(%(id="plugin-card-#{key}"))
      end
      expect(response.body).to include(connect_tool_integrations_path("slack"))
    end
  end

  describe "POST /settings/integrations_keys" do
    it "verifies then stores an active org-scoped key that agents actually use" do
      stub_anthropic_models

      post settings_integrations_keys_path,
           params: { provider_id: "anthropic", api_key: "  sk-ant-org-replacement-777  " },
           headers: html_form_headers

      integration = ToolIntegration.find_by(organization: organization, provider: "anthropic")
      expect(integration).to be_present
      expect(integration.is_active?).to be(true)
      expect(integration.decrypted_credentials["api_key"]).to eq("sk-ant-org-replacement-777")
      expect(integration.config["last_verified_at"]).to be_present
      expect(response).to redirect_to(settings_integrations_path)

      agent = create(:agent, organization: organization, provider: "anthropic")
      expect(agent.api_key).to eq("sk-ant-org-replacement-777")
      expect(raw_credentials(integration.id)).not_to include("sk-ant-org-replacement-777")
    end

    it "refuses a rejected key without touching the stored credential" do
      stub_anthropic_models(status: 401)
      row = create(:tool_integration, organization: organization, provider: "anthropic",
                                      credentials: { "api_key" => "keep-me" })

      post settings_integrations_keys_path,
           params: { provider_id: "anthropic", api_key: "bad-key" },
           headers: html_form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("rejected these credentials")
      expect(row.reload.decrypted_credentials["api_key"]).to eq("keep-me")
      expect(row.config["last_verification_error"]).to eq("invalid_credentials")
    end

    it "refuses an empty key" do
      post settings_integrations_keys_path,
           params: { provider_id: "anthropic", api_key: "   " },
           headers: html_form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ToolIntegration.find_by(organization: organization, provider: "anthropic")).to be_nil
    end

    it "rejects providers that are not model providers" do
      post settings_integrations_keys_path,
           params: { provider_id: "stripe", api_key: "nope" },
           headers: html_form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Unknown provider")
    end

    it "refuses a non-owner member" do
      member = create(:user)
      create(:membership, user: member, organization: organization)
      api_login(member)

      post settings_integrations_keys_path,
           params: { provider_id: "anthropic", api_key: "mine-key" },
           headers: html_form_headers

      expect(response).to have_http_status(:forbidden)
      expect(ToolIntegration.find_by(organization: organization, provider: "anthropic")).to be_nil
    end
  end

  describe "connection and model management" do
    let!(:connection) do
      stub_anthropic_models
      create(:tool_integration, organization: organization, provider: "anthropic",
                                credentials: { "api_key" => "sk-ant-org-1" })
    end

    it "disables and re-enables a connection, clearing a stale default" do
      organization.update!(settings: { default_model: { provider_id: "anthropic", model_id: "claude-test" } })

      post settings_integrations_connection_path,
           params: { provider_id: "anthropic", is_active: false }, headers: html_form_headers
      expect(connection.reload.is_active?).to be(false)
      expect(organization.reload.settings["default_model"]).to be_nil

      post settings_integrations_connection_path,
           params: { provider_id: "anthropic", is_active: true }, headers: html_form_headers
      expect(connection.reload.is_active?).to be(true)
    end

    it "disables and re-enables a discovered model" do
      post settings_integrations_model_path,
           params: { provider_id: "anthropic", model_id: "claude-test", is_active: false },
           headers: html_form_headers
      expect(connection.reload.config["disabled_models"]).to eq([ "claude-test" ])

      post settings_integrations_model_path,
           params: { provider_id: "anthropic", model_id: "claude-test", is_active: true },
           headers: html_form_headers
      expect(connection.reload.config["disabled_models"]).to eq([])
    end

    it "refuses to manage a model the provider never discovered" do
      post settings_integrations_model_path,
           params: { provider_id: "anthropic", model_id: "invented", is_active: false },
           headers: html_form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(connection.reload.config["disabled_models"]).to be_blank
    end

    it "sets a validated organization default and refuses an unavailable one" do
      selected = Llm::ProviderConnection.new(provider: "anthropic", integration: connection, model: "claude-test")
      Llm::InferenceTracker.record(selected, "claude-test", api_family: selected.api_family,
        fingerprint: selected.inference_fingerprint)

      post settings_integrations_default_model_path,
           params: { provider_id: "anthropic", model_id: "claude-test" }, headers: html_form_headers
      expect(organization.reload.settings["default_model"]).to eq("provider_id" => "anthropic", "model_id" => "claude-test")

      post settings_integrations_default_model_path,
           params: { provider_id: "anthropic", model_id: "invented" }, headers: html_form_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses an unverified organization default" do
      post settings_integrations_default_model_path,
           params: { provider_id: "anthropic", model_id: "claude-test" }, headers: html_form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("successful real inference")
      expect(organization.reload.settings["default_model"]).to be_nil
    end

    it "refreshes discovery and records the verification time" do
      post settings_integrations_refresh_path, headers: html_form_headers

      expect(response).to redirect_to(settings_integrations_path)
      expect(connection.reload.config["last_verified_at"]).to be_present
    end
  end
end

RSpec.describe "Settings integrations (anonymous)", type: :request do
  it "sends anonymous visitors to the login wall" do
    get settings_integrations_path

    expect(response).to have_http_status(:redirect)
    expect(response).to redirect_to(login_path)
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength,
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleDescribes
