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
