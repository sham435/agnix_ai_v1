# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength,
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleDescribes

# Settings › Integrations used to be a read-only list that rendered
# `ToolIntegration::PROVIDERS` with a status badge and NO controls, so every
# service looked permanently "Inactive" with nothing to click. Two things had
# to become true:
#
#   1. every service exposes a real action (Connect / Enable / Disable /
#      Manage) — shared with the /integrations marketplace card;
#   2. model provider credentials (anthropic, openai, …) are settable per
#      organization, because `Agent#api_key` prefers an active org
#      ToolIntegration over Rails credentials and ENV. Before this there was
#      no in-app way to replace a dead or out-of-credit server key.
RSpec.describe "Settings integrations", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { create(:user) }

  before do
    create(:membership, user: user, organization: organization)
    api_login(user)
  end

  def html_form_headers
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" }
  end

  def raw_credentials(id)
    ToolIntegration.connection
      .select_value("SELECT credentials::text FROM tool_integrations WHERE id = '#{id}'")
      .to_s
  end

  describe "GET /settings/integrations" do
    it "offers a credential form for every model provider" do
      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      %w[anthropic openai google ollama opencode bonsai].each do |provider|
        expect(response.body).to include(%(id="provider-key-row-#{provider}"))
      end
      expect(response.body).to include(%(name="api_key"))
      expect(response.body).to include(%(name="provider"))
      %w[anthropic openai google ollama opencode bonsai].each do |provider|
        expect(response.body).to include(%(value="#{provider}"))
      end
      expect(response.body).to include("Save key")
    end

    it "gives every marketplace plugin a connect action when nothing is configured" do
      get settings_integrations_path

      expect(response).to have_http_status(:ok)
      Tools::Catalog.keys.each do |key|
        expect(response.body).to include(%(id="plugin-card-#{key}"))
      end
      expect(response.body).to include("Connect")
      expect(response.body).to include(connect_tool_integrations_path("slack"))
    end

    it "swaps the plugin chip for a Disable action and the provider row for Enable" do
      create(:tool_integration, organization: organization, provider: "slack")
      paused = create(:tool_integration, organization: organization, provider: "anthropic",
                                         name: "Anthropic API", is_active: false,
                                         credentials: { "api_key" => "sk-ant-paused-9000" })

      get settings_integrations_path

      expect(response.body).to include("Disable")
      expect(response.body).to include("Connected")
      expect(response.body).to include(toggle_tool_integration_path(paused))
      expect(response.body).to include("Enable")
      expect(response.body).to include("Organization key (paused)")
      # The secret itself is never rendered — only the last-4 fingerprint.
      expect(response.body).not_to include("sk-ant-paused-9000")
      expect(response.body).to include("9000")
    end
  end

  describe "POST /settings/integrations_keys" do
    it "stores an active org-scoped provider key that agents actually use" do
      post settings_integrations_keys_path,
           params: { provider: "anthropic", api_key: "  sk-ant-org-replacement-777  " },
           headers: html_form_headers

      integration = ToolIntegration.find_by(organization: organization, provider: "anthropic")
      expect(integration).to be_present
      expect(integration.name).to eq("Anthropic API")
      expect(integration.is_active?).to be(true)
      expect(integration.reload.decrypted_credentials["api_key"]).to eq("sk-ant-org-replacement-777")
      expect(response).to redirect_to(settings_integrations_path)

      # Precedence: this row beats ENV/credentials for agents on that provider.
      agent = create(:agent, organization: organization, provider: "anthropic")
      expect(agent.api_key).to eq("sk-ant-org-replacement-777")

      # Encrypted at rest, and never echoed back in full by the page.
      expect(raw_credentials(integration.id)).not_to include("sk-ant-org-replacement-777")
      get settings_integrations_path
      expect(response.body).not_to include("sk-ant-org-replacement-777")
      expect(response.body).to include("-777")
    end

    it "replaces the key in place instead of adding a second row per provider" do
      existing = create(:tool_integration, organization: organization, provider: "openai",
                                          name: "OpenAI API", credentials: { "api_key" => "old-key" })

      post settings_integrations_keys_path,
           params: { provider: "openai", api_key: "new-openai-key" },
           headers: html_form_headers

      expect(ToolIntegration.where(organization: organization, provider: "openai").count).to eq(1)
      expect(existing.reload.decrypted_credentials["api_key"]).to eq("new-openai-key")
    end

    it "keeps a paused row paused only until the operator flips it back on" do
      row = create(:tool_integration, organization: organization, provider: "anthropic",
                                     name: "Anthropic API", is_active: false)

      post settings_integrations_keys_path,
           params: { provider: "anthropic", api_key: "fresh-key" },
           headers: html_form_headers

      expect(row.reload.is_active?).to be(true)

      post toggle_tool_integration_path(row), headers: html_form_headers
      expect(row.reload.is_active?).to be(false)

      post toggle_tool_integration_path(row), headers: html_form_headers
      expect(row.reload.is_active?).to be(true)
    end

    it "refuses an empty key and never destroys the stored credential" do
      row = create(:tool_integration, organization: organization, provider: "anthropic",
                                     name: "Anthropic API", credentials: { "api_key" => "keep-me" })

      post settings_integrations_keys_path,
           params: { provider: "anthropic", api_key: "   " },
           headers: html_form_headers

      expect(response).to redirect_to(settings_integrations_path)
      expect(row.reload.decrypted_credentials["api_key"]).to eq("keep-me")
      expect(flash[:alert]).to be_present
    end

    it "rejects providers that are not model providers" do
      expect {
        post settings_integrations_keys_path,
             params: { provider: "stripe", api_key: "nope" },
             headers: html_form_headers
      }.not_to change { ToolIntegration.where(provider: "stripe").count }

      expect(response).to redirect_to(settings_integrations_path)
      expect(flash[:alert]).to eq("Unknown provider.")
    end

    it "isolates rows per organization" do
      other_org = create(:organization)
      other_user = create(:user)
      create(:membership, user: other_user, organization: other_org)

      post settings_integrations_keys_path,
           params: { provider: "anthropic", api_key: "mine-key" },
           headers: html_form_headers

      expect(ToolIntegration.find_by(organization: organization, provider: "anthropic")).to be_present
      expect(ToolIntegration.find_by(organization: other_org, provider: "anthropic")).to be_nil
    end
  end
end

# Kept in its own group: the signed-in group's before hook logs a user in, so this
# example has to reach the page with a clean session.
RSpec.describe "Settings integrations (anonymous)", type: :request do
  it "sends anonymous visitors to the login wall" do
    get settings_integrations_path

    expect(response).to have_http_status(:redirect)
    expect(response).to redirect_to(login_path)
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength,
# rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/MultipleDescribes

# rubocop:enable RSpec/MultipleDescribes
