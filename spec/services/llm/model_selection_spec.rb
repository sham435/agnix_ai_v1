require "rails_helper"

RSpec.describe Llm::ModelSelection do
  subject(:selection) { described_class.new(user: user, organization: organization, conversation: conversation) }

  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user, settings: { default_model: { provider_id: "bonsai", model_id: "bonsai-2-27b" } }) }
  let(:agent) { create(:agent, organization: organization, tools: []) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  it "uses the organization default" do
    expect(selection.selected).to eq("provider_id" => "bonsai", "model_id" => "bonsai-2-27b")
  end

  it "prioritizes the organization-scoped user preference" do
    user.update!(settings: { preferred_models: { organization.id => { provider_id: "anthropic", model_id: "preferred" } } })
    expect(selection.selected["model_id"]).to eq("preferred")
  end

  it "prioritizes the conversation selection" do
    conversation.update!(metadata: { selected_model: { provider_id: "anthropic", model_id: "conversation-model" } })
    expect(selection.selected["model_id"]).to eq("conversation-model")
  end

  it "supports an explicit default reset" do
    conversation.update!(metadata: { use_organization_default: true })
    user.update!(settings: { preferred_models: { organization.id => { provider_id: "anthropic", model_id: "preferred" } } })
    expect(selection.selected["provider_id"]).to eq("bonsai")
  end

  it "does not inherit a preference from another organization" do
    user.update!(settings: { preferred_models: { SecureRandom.uuid => { provider_id: "anthropic", model_id: "foreign" } } })
    expect(selection.selected["provider_id"]).to eq("bonsai")
  end

  it "rejects non-conversation default resets" do
    expect { selection.select!(provider_id: nil, model_id: nil, scope: "organization", use_organization_default: true) }.to raise_error(Llm::ModelCatalogue::Error, /only for a conversation/)
  end

  # Assignment examples verify both authorization/error behavior and persisted state.
  # rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength, RSpec/MultipleExpectations
  describe "organization default assignment" do
    let(:model_id) { "meta/llama-3.3-70b-instruct" }
    let!(:nvidia_connection) do
      create(:tool_integration, organization: organization, provider: "nvidia_nim",
                                credentials: { api_key: "test-only-model-selection-key" },
                                config: { "models" => { model_id => { "api_family" => "chat_completions" } } })
    end

    before do
      organization.update!(settings: {})
    end

    it "delegates to owner-authorized verified-default enforcement" do
      selected = Llm::ProviderConnection.new(provider: "nvidia_nim", integration: nvidia_connection, model: model_id)
      Llm::InferenceTracker.record(selected, model_id, api_family: selected.api_family,
        fingerprint: selected.inference_fingerprint)

      result = selection.select!(provider_id: "nvidia_nim", model_id: model_id, scope: "organization")

      expect(result).to eq("provider_id" => "nvidia_nim", "model_id" => model_id)
      expect(organization.reload.settings["default_model"]).to eq(result)
    end

    it "rejects an unverified model without changing the default" do
      expect { selection.select!(provider_id: "nvidia_nim", model_id: model_id, scope: "organization") }
        .to raise_error(Llm::ModelCatalogue::Error) { |error| expect(error.code).to eq("inference_unverified") }

      expect(organization.reload.settings["default_model"]).to be_nil
    end

    it "rejects a non-owner even when the model has verified inference" do
      selected = Llm::ProviderConnection.new(provider: "nvidia_nim", integration: nvidia_connection, model: model_id)
      Llm::InferenceTracker.record(selected, model_id, api_family: selected.api_family,
        fingerprint: selected.inference_fingerprint)
      non_owner = create(:user)

      expect { described_class.new(user: non_owner, organization: organization)
        .select!(provider_id: "nvidia_nim", model_id: model_id, scope: "organization") }
        .to raise_error(Llm::ModelCatalogue::Error) { |error| expect(error.code).to eq("owner_required") }

      expect(organization.reload.settings["default_model"]).to be_nil
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/ExampleLength, RSpec/MultipleExpectations

  it "rejects inference without a configured selection" do
    organization.update!(settings: {})
    expect { selection.snapshot! }.to raise_error(Llm::ModelCatalogue::Error, /Choose a model/)
  end

  it "rejects a default reset without a configured default" do
    organization.update!(settings: {})
    expect { selection.select!(provider_id: nil, model_id: nil, use_organization_default: true) }.to raise_error(Llm::ModelCatalogue::Error, /No organization default/)
  end

  it "routes a selected model through the existing provider client" do
    create(:tool_integration, organization: organization, provider: "anthropic", credentials: { api_key: "selected-organization-key" })
    conversation.update!(metadata: { selected_model: { provider_id: "anthropic", model_id: "discovered-cloud-model" } })
    catalogue = instance_double(Llm::ModelCatalogue, resolve!: { supports_tools: true })
    allow(Llm::ModelCatalogue).to receive(:new).with(organization).and_return(catalogue)
    expect(AgentRunner.new(agent: agent, user: user, conversation: conversation).send(:build_client_for_agent)).to have_attributes(provider: "anthropic", model: "discovered-cloud-model", api_key: "selected-organization-key")
  end
end
