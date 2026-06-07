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
