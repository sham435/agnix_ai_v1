# frozen_string_literal: true

# Phase 4d — Plugins marketplace HTTP contract. Covers the catalog-driven
# grid (index), the modal credential editor (connect), plugin detail, the
# enable/disable toggle (turbo_stream + html fallback), removal, cross-org
# isolation, and the security-critical guarantee that provider credentials
# reach the database encrypted (raw column text never contains the secret)
# while the model transparently round-trips them.
# M15 H1: the whole surface is admin/owner-only and credential fields are
# write-only — the happy paths below run as an org admin, and the H1 block
# proves members are refused and stored secrets never reach HTML.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe "Plugins marketplace", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization) }
  let(:other_user) { create(:user) }
  let(:other_org) { create(:organization) }

  before do
    create(:membership, user: user, organization: organization, role: "admin")
    create(:membership, user: other_user, organization: other_org)
  end

  def form_headers
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"],
      "ACCEPT" => "text/vnd.turbo-stream.html, text/html" }
  end

  def raw_credentials(id)
    ToolIntegration.connection
      .select_value("SELECT credentials::text FROM tool_integrations WHERE id = '#{id}'")
      .to_s
  end

  describe "authentication" do
    it "sends anonymous visitors to the login wall" do
      get tool_integrations_path
      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET /integrations" do
    it "renders one catalog card per plugin with not-connected state" do
      api_login(user)

      get tool_integrations_path
      expect(response).to have_http_status(:ok)

      Tools::Catalog.keys.each do |key|
        expect(response.body).to include(%(id="plugin-card-#{key}"))
      end
      expect(response.body).to include("Not connected")
      expect(response.body).to include("Manual setup")
    end

    it "marks connected rows and pauses them distinctly" do
      create(:tool_integration, organization: organization, provider: "slack")
      create(:tool_integration, organization: organization, provider: "stripe", is_active: false)
      api_login(user)

      get tool_integrations_path
      expect(response.body).to include("Connected")
      expect(response.body).to include("Paused")
      expect(response.body).to include("1 active")
    end
  end

  describe "GET /integrations/connect/:key" do
    it "renders the credential editor into the modal frame with catalog fields" do
      api_login(user)

      get connect_tool_integrations_path("slack")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(<turbo-frame id="modal">))
      expect(response.body).to include(%(name="tool_integration[credentials][api_key]"))
      expect(response.body).to include("xoxb-")
      expect(response.body).to include("Connect Slack")
    end

    it "maps config fields for providers that need them (webhook url)" do
      api_login(user)

      get connect_tool_integrations_path("webhook")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(name="tool_integration[config][webhook_url]"))
    end

    it "switches existing connections to Manage (PATCH) without echoing secrets" do
      slack_row = create(:tool_integration, organization: organization, provider: "slack")
      api_login(user)

      get connect_tool_integrations_path("slack")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Manage Slack")
      expect(response.body).to include(%(action="#{tool_integration_path(slack_row)}"))
      expect(response.body).to include(%(name="_method"))
      expect(response.body).to include(%(value="patch"))
      expect(response.body).not_to include("sk_test_123")
      expect(response.body).not_to include("whsec_test")
    end

    it "404s for keys the catalog does not know" do
      api_login(user)

      get connect_tool_integrations_path("nope")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /integrations (connect submit)" do
    it "creates the org row, encrypts credentials at rest, and redirects" do
      api_login(user)

      post tool_integrations_path,
           params: { tool_integration: { name: "Team Slack", provider: "slack",
                                         credentials: { api_key: "xoxb-super-secret-token" } } },
           headers: form_headers

      integration = ToolIntegration.where(organization: organization, provider: "slack").first
      expect(integration).not_to be_nil
      expect(response).to redirect_to(tool_integration_path(integration))

      # Model-level round trip is transparent; the stored bytes are not plaintext.
      expect(integration.reload.decrypted_credentials["api_key"]).to eq("xoxb-super-secret-token")
      raw = raw_credentials(integration.id)
      expect(raw).not_to include("xoxb-super-secret-token")
      expect(raw).not_to include("api_key")
    end

    it "stores config values unencrypted-only for secrets: webhook url is plain config" do
      api_login(user)

      post tool_integrations_path,
           params: { tool_integration: { name: "Ping", provider: "webhook",
                                         config: { webhook_url: "https://example.com/hooks/agent" } } },
           headers: form_headers

      integration = ToolIntegration.where(organization: organization, provider: "webhook").first
      expect(integration.config["webhook_url"]).to eq("https://example.com/hooks/agent")
    end

    it "re-renders 422 when the row is invalid (missing provider)" do
      api_login(user)

      post tool_integrations_path,
           params: { tool_integration: { name: "Broken", provider: "" } },
           headers: form_headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /integrations/:id/toggle" do
    let!(:slack) { create(:tool_integration, organization: organization, provider: "slack") }

    it "flips off and replaces the card in place over turbo_stream" do
      api_login(user)

      post toggle_tool_integration_path(slack), headers: form_headers

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("plugin-card-slack")
      expect(slack.reload.is_active?).to be(false)
    end

    it "flips back on and falls back to a redirect for html accepts" do
      slack.update!(is_active: false)
      api_login(user)

      post toggle_tool_integration_path(slack),
           headers: { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" }

      expect(response).to have_http_status(:redirect)
      expect(slack.reload.is_active?).to be(true)
    end

    it "404s for another organization's row" do
      foreign = create(:tool_integration, organization: other_org, provider: "notion")
      api_login(user)

      post toggle_tool_integration_path(foreign), headers: api_headers
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.is_active?).to be(true)
    end
  end

  describe "GET /integrations/plugin/:key" do
    it "lists real catalog tools with namespaced names and summaries" do
      api_login(user)

      get plugin_tool_integrations_path("slack")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slack.post_message")
      expect(response.body).to include("Send a message to a Slack channel.")
    end

    it "is honest about tool-less plugins (google)" do
      api_login(user)

      get plugin_tool_integrations_path("google")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No agent tools yet")
    end

    it "404s for unknown keys" do
      api_login(user)

      get plugin_tool_integrations_path("stripe-not-real")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /integrations/:id" do
    it "removes only the current organization's row" do
      mine = create(:tool_integration, organization: organization, provider: "slack")
      theirs = create(:tool_integration, organization: other_org, provider: "stripe")
      api_login(user)

      delete tool_integration_path(mine), headers: api_headers
      expect(response).to redirect_to(tool_integrations_path)
      expect(ToolIntegration.where(id: mine.id)).to be_empty
      expect(ToolIntegration.where(id: theirs.id).exists?).to be(true)
    end
  end

  describe "legacy manual setup stays usable" do
    it "renders the classic new form preselected by provider" do
      api_login(user)

      get new_tool_integration_path(provider: "github")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("github")
    end

    it "updates an existing row through the classic edit path" do
      integration = create(:tool_integration, organization: organization)
      api_login(user)

      patch tool_integration_path(integration),
            params: { tool_integration: { name: "Renamed Billing" } },
            headers: form_headers

      expect(response).to redirect_to(tool_integration_path(integration))
      expect(integration.reload.name).to eq("Renamed Billing")
    end
  end

  describe "H1 — admin-only access and write-only credentials" do
    let(:member) { create(:user) }
    let!(:stored) { create(:tool_integration, organization: organization, provider: "slack") }

    before { create(:membership, user: member, organization: organization) }

    it "refuses a plain member every read surface without leaking secrets" do
      api_login(member)

      [ tool_integrations_path,
        tool_integration_path(stored),
        edit_tool_integration_path(stored),
        new_tool_integration_path,
        connect_tool_integrations_path("slack"),
        plugin_tool_integrations_path("slack") ].each do |path|
        get path, headers: form_headers
        expect(response).to redirect_to(conversations_path)
        expect(response.body).not_to include("sk_test_123")
        expect(response.body).not_to include("whsec_test")
      end
    end

    it "refuses a plain member every write surface and leaves rows untouched" do
      api_login(member)
      original = stored.attributes.slice("name", "credentials", "is_active")

      post tool_integrations_path,
           params: { tool_integration: { name: "Evil", provider: "notion",
                                         credentials: { api_key: "xoxb-evil" } } },
           headers: form_headers
      expect(response).to redirect_to(conversations_path)
      expect(ToolIntegration.where(organization: organization, provider: "notion")).to be_empty

      patch tool_integration_path(stored),
            params: { tool_integration: { name: "Hacked", credentials: { api_key: "xoxb-evil" } } },
            headers: form_headers
      expect(response).to redirect_to(conversations_path)

      post toggle_tool_integration_path(stored), headers: form_headers
      expect(response).to redirect_to(conversations_path)

      delete tool_integration_path(stored), headers: form_headers
      expect(response).to redirect_to(conversations_path)

      expect(stored.reload.attributes.slice("name", "credentials", "is_active")).to eq(original)
      expect(ToolIntegration.where(id: stored.id).exists?).to be(true)
    end

    it "lets the organization owner manage integrations despite a member-role membership" do
      owner = create(:user)
      owned_org = create(:organization, owner: owner)
      create(:membership, user: owner, organization: owned_org, role: "member")
      api_login(owner)

      get tool_integrations_path, headers: form_headers
      expect(response).to have_http_status(:ok)
    end

    it "never renders stored secrets in the legacy edit form" do
      api_login(user)

      get edit_tool_integration_path(stored), headers: form_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("sk_test_123")
      expect(response.body).not_to include("whsec_test")
      expect(response.body).to include("Leave blank to keep current key")
      expect(response.body).to include("Leave blank to keep current secret")
    end

    it "never renders stored secrets in the manage modal" do
      api_login(user)

      get connect_tool_integrations_path("slack"), headers: form_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("sk_test_123")
      expect(response.body).not_to include("whsec_test")
      expect(response.body).to include("Leave blank to keep current value")
    end

    it "keeps stored secrets when the manage form submits blank credential fields" do
      api_login(user)

      patch tool_integration_path(stored),
            params: { tool_integration: { name: "Slack Renamed",
                                          credentials: { api_key: "", webhook_secret: "" } } },
            headers: form_headers

      expect(response).to redirect_to(tool_integration_path(stored))
      stored.reload
      expect(stored.name).to eq("Slack Renamed")
      expect(stored.decrypted_credentials["api_key"]).to eq("sk_test_123")
      expect(stored.decrypted_credentials["webhook_secret"]).to eq("whsec_test")
    end

    it "replaces a secret when a new value is submitted and keeps the others" do
      api_login(user)

      patch tool_integration_path(stored),
            params: { tool_integration: { credentials: { api_key: "xoxb-replacement" } } },
            headers: form_headers

      expect(response).to redirect_to(tool_integration_path(stored))
      creds = stored.reload.decrypted_credentials
      expect(creds["api_key"]).to eq("xoxb-replacement")
      expect(creds["webhook_secret"]).to eq("whsec_test")
    end

    it "preserves credentials when the update carries no credential fields at all" do
      api_login(user)

      patch tool_integration_path(stored),
            params: { tool_integration: { name: "Name Only" } },
            headers: form_headers

      expect(response).to redirect_to(tool_integration_path(stored))
      expect(stored.reload.decrypted_credentials)
        .to eq("api_key" => "sk_test_123", "webhook_secret" => "whsec_test")
    end

    it "drops credential keys outside the whitelist" do
      api_login(user)

      patch tool_integration_path(stored),
            params: { tool_integration: { credentials: { api_key: "xoxb-ok", evil_key: "payload" } } },
            headers: form_headers

      creds = stored.reload.decrypted_credentials
      expect(creds["api_key"]).to eq("xoxb-ok")
      expect(creds).not_to have_key("evil_key")
    end

    it "drops config keys outside the non-secret whitelist" do
      api_login(user)

      patch tool_integration_path(stored),
            params: { tool_integration: { config: { webhook_url: "https://example.com/hook", evil: "payload" } } },
            headers: form_headers

      config = stored.reload.config
      expect(config["webhook_url"]).to eq("https://example.com/hook")
      expect(config).not_to have_key("evil")
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
