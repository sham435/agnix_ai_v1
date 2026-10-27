# Provider routing is asserted as a triple per example - adapter class, endpoint,
# model id - because a route that lands on the wrong host should fail loudly on
# every dimension it violates, so these two cops are opted out for this file (the
# same way spec/services/llm/client_spec.rb does it).
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Agent, type: :model do
  subject { build(:agent) }

  it { is_expected.to validate_presence_of(:name) }
  it { is_expected.to validate_presence_of(:model) }
  it { is_expected.to belong_to(:organization) }
  it { is_expected.to have_many(:conversations).dependent(:destroy) }
  it { is_expected.to have_many(:runs).dependent(:destroy) }

  describe "#llm_client" do
    it "returns an LLM client with correct provider" do
      agent = create(:agent, provider: "anthropic", model: "claude-sonnet-4-6")
      client = agent.llm_client
      expect(client.provider).to eq("anthropic")
      expect(client.model).to eq("claude-sonnet-4-6")
    end

    it "routes the bonsai provider to the local llama.cpp server" do
      agent = create(:agent, provider: "bonsai", model: "bonsai-27b")
      adapter = agent.llm_client.send(:adapter)
      expect(adapter).to be_a(Llm::OpenaiAdapter)
      expect(adapter.base_url).to eq("http://127.0.0.1:8910/v1")
      expect(adapter.api_key).to eq("local")
    end

    it "routes bonsai-2-27b to the ternary Bonsai 2 server on port 8080" do
      agent = create(:agent, provider: "bonsai", model: "bonsai-2-27b")
      adapter = agent.llm_client.send(:adapter)
      expect(adapter).to be_a(Llm::OpenaiAdapter)
      expect(adapter.base_url).to eq("http://127.0.0.1:8080/v1")
      expect(adapter.api_key).to eq("local")
    end

    # openrouter is a provider of its own now, not an "openai" agent wearing an
    # sk-or-v1 key: selecting it routes to the gateway regardless of key prefix,
    # and the route id (colon + ":free" suffix included) is sent untouched.
    it "routes the openrouter provider to the OpenRouter gateway with the route id verbatim" do
      agent = create(:agent, provider: "openrouter", model: "recursive/flint-v1.0:free")
      adapter = agent.llm_client.send(:adapter)

      expect(adapter).to be_a(Llm::OpenaiAdapter)
      expect(adapter.base_url).to eq("https://openrouter.ai/api/v1")
      expect(adapter.model).to eq("recursive/flint-v1.0:free")
    end

    it "sends an openrouter agent's model id unchanged back to the API" do
      agent = create(:agent, provider: "openrouter", model: "recursive/flint-v1.0:free")

      expect(agent.reload.model).to eq("recursive/flint-v1.0:free")
      expect(agent.openrouter?).to be(true)
    end

    it "prefers the organization's stored openrouter key over the environment" do
      org = create(:organization)
      create(:tool_integration, organization: org, provider: "openrouter", name: "OpenRouter API",
                                credentials: { "api_key" => "sk-or-v1-org-stored-key" })
      agent = create(:agent, organization: org, provider: "openrouter", model: "recursive/flint-v1.0:free")

      expect(agent.api_key).to eq("sk-or-v1-org-stored-key")
      expect(agent.llm_client.send(:adapter).api_key).to eq("sk-or-v1-org-stored-key")
    end
  end

  describe "#enabled_tools" do
    it "returns only enabled tools" do
      agent = create(:agent, tools: [
        { name: "calculator", enabled: true },
        { name: "web_search", enabled: false }
      ])
      expect(agent.enabled_tools.map { |t| t[:name] || t["name"] }).to eq(["calculator"])
    end
  end

  describe "#duplicate" do
    it "creates a copy with a new name" do
      agent = create(:agent, name: "Original", slug: "original")
      user = create(:user)
      copy = agent.duplicate(user)
      expect(copy.name).to eq("Original (Copy)")
      expect(copy.slug).to be_nil
    end
  end
end
