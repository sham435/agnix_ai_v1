require "rails_helper"

RSpec.describe "Dynamic model catalogue", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:agent) { create(:agent, organization: organization, tools: []) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:csrf) do
    get "/api/v1/csrf"
    response.parsed_body["token"]
  end

  before do
    Rails.cache.clear
    create(:membership, :owner, user: user, organization: organization)
    stub_request(:get, "http://127.0.0.1:8080/v1/models").to_return(status: 200, body: { data: [ { id: "local" } ] }.to_json)
    post "/api/v1/sessions", params: { email: user.email, password: "password123" }
  end

  it "returns the organization catalogue" do
    get "/api/v1/models"
    expect(response.parsed_body["models"]).to include(hash_including("model_id" => "bonsai-2-27b"))
  end

  it "persists a conversation selection without rewriting its agent" do
    patch "/api/v1/conversations/#{conversation.id}/model", params: { provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }
    expect(conversation.reload.metadata["selected_model"]).to eq("provider_id" => "bonsai", "model_id" => "bonsai-2-27b")
  end

  it "preserves the shared agent assignment" do
    patch "/api/v1/conversations/#{conversation.id}/model", params: { provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }
    expect(agent.reload.provider).to eq("anthropic")
  end

  it "rejects arbitrary models without persistence" do
    patch "/api/v1/conversations/#{conversation.id}/model", params: { provider_id: "anthropic", model_id: "invented" }, headers: { "X-CSRF-Token" => csrf }
    expect(response.parsed_body["error_code"]).to eq("model_unavailable")
  end

  it "rejects cross-user conversations" do
    foreign = create(:conversation)
    get "/api/v1/models", params: { conversation_id: foreign.id }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects cross-organization requests" do
    get "/api/v1/models", params: { organization_id: SecureRandom.uuid }
    expect(response).to have_http_status(:forbidden)
  end

  it "persists a user preference scoped to this organization" do
    patch "/api/v1/models/selection", params: { scope: "user", provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }
    expect(user.reload.settings.dig("preferred_models", organization.id, "model_id")).to eq("bonsai-2-27b")
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it "sets an owner-controlled organization default after fingerprinted inference" do
    create(:tool_integration, organization: organization, provider: "bonsai", credentials: {})
    selected = Llm::ProviderConnection.resolve(organization: organization, provider: "bonsai", model: "bonsai-2-27b")
    Llm::InferenceTracker.record(selected, "bonsai-2-27b", api_family: selected.api_family,
      fingerprint: selected.inference_fingerprint)

    patch "/api/v1/models/selection", params: { scope: "organization", provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }
    expect(organization.reload.settings.dig("default_model", "provider_id")).to eq("bonsai")
  end

  it "rejects an unverified organization default without persistence" do
    patch "/api/v1/models/selection", params: { scope: "organization", provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error_code"]).to eq("inference_unverified")
    expect(organization.reload.settings["default_model"]).to be_nil
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it "rejects unknown disabled model IDs through provider configuration without persisting them" do
    connection = create(:tool_integration, organization: organization, provider: "bonsai", credentials: {})

    patch "/api/v1/models/providers/bonsai", params: { disabled_models: [ "invented" ] },
      headers: { "X-CSRF-Token" => csrf }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error_code"]).to eq("model_unavailable")
    expect(connection.reload.config["disabled_models"]).to be_nil
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it "clears a disabled organization default and refuses to select it again" do
    connection = create(:tool_integration, organization: organization, provider: "bonsai", credentials: {})
    organization.update!(settings: { default_model: { provider_id: "bonsai", model_id: "bonsai-2-27b" } })

    patch "/api/v1/models/providers/bonsai", params: { disabled_models: [ "bonsai-2-27b" ] },
      headers: { "X-CSRF-Token" => csrf }

    expect(response).to have_http_status(:ok)
    expect(connection.reload.config["disabled_models"]).to eq([ "bonsai-2-27b" ])
    expect(organization.reload.settings["default_model"]).to be_nil

    patch "/api/v1/models/selection",
      params: { scope: "organization", provider_id: "bonsai", model_id: "bonsai-2-27b" },
      headers: { "X-CSRF-Token" => csrf }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error_code"]).to eq("model_unavailable")
    expect(organization.reload.settings["default_model"]).to be_nil
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it "refuses provider configuration from a non-owner member" do
    member = create(:user)
    create(:membership, user: member, organization: organization)
    connection = create(:tool_integration, organization: organization, provider: "bonsai", credentials: {})
    post "/api/v1/sessions", params: { email: member.email, password: "password123" }

    patch "/api/v1/models/providers/bonsai", params: { disabled_models: [ "bonsai-2-27b" ] },
      headers: { "X-CSRF-Token" => csrf }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error_code"]).to eq("owner_required")
    expect(connection.reload.config["disabled_models"]).to be_nil
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  it "offers an explicit organization-default reset" do
    organization.update!(settings: { default_model: { provider_id: "bonsai", model_id: "bonsai-2-27b" } })
    patch "/api/v1/conversations/#{conversation.id}/model", params: { use_organization_default: true }, headers: { "X-CSRF-Token" => csrf }
    expect(conversation.reload.metadata["use_organization_default"]).to be true
  end

  it "refuses a default reset when no default is configured" do
    patch "/api/v1/conversations/#{conversation.id}/model", params: { use_organization_default: true }, headers: { "X-CSRF-Token" => csrf }
    expect(response.parsed_body["error_code"]).to eq("model_required")
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it "switches from Bonsai to Anthropic and back without touching the agent" do
    create(:tool_integration, organization: organization, provider: "anthropic", credentials: { api_key: "sk-ant-test" })
    stub_request(:get, %r{\Ahttps://api\.anthropic\.com/v1/models})
      .to_return(status: 200, body: { data: [ { id: "claude-test" } ], has_more: false }.to_json)

    patch "/api/v1/conversations/#{conversation.id}/model", params: { provider_id: "anthropic", model_id: "claude-test" }, headers: { "X-CSRF-Token" => csrf }
    expect(conversation.reload.metadata["selected_model"]).to eq("provider_id" => "anthropic", "model_id" => "claude-test")

    patch "/api/v1/conversations/#{conversation.id}/model", params: { provider_id: "bonsai", model_id: "bonsai-2-27b" }, headers: { "X-CSRF-Token" => csrf }
    expect(conversation.reload.metadata["selected_model"]).to eq("provider_id" => "bonsai", "model_id" => "bonsai-2-27b")
    expect(agent.reload.provider).to eq("anthropic")
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  it "rejects model refresh without CSRF authorization" do
    post "/api/v1/models/refresh"
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
