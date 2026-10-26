# spec/services/agents/templates_spec.rb

# Phase 5a — Curated template catalog integrity. Every advertised template must
# be instantiable: real provider/model pairs from Agent::MODELS, url-safe unique
# slugs, resolvable tools, and complete keys. Several assertions per example by
# design — a broken template should fail loudly on each dimension it violates.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MessageSpies, RSpec/StubbedMock, RSpec/NestedGroups

require "rails_helper"

RSpec.describe Agents::Templates, type: :service do
  it "curates at least eight templates carrying every required key" do
    expect(described_class.all.size).to be >= 8
    described_class.all.each do |template|
      expect(template.keys.sort).to eq(described_class::REQUIRED_KEYS.sort)
      expect(template[:name]).to be_present
      expect(template[:description]).to be_present
      expect(template[:system_prompt]).to be_present
      expect(template[:icon]).to be_present
      expect(template[:category]).to be_present
    end
  end

  it "offers only provider/model pairs the agent form can actually run" do
    described_class.all.each do |template|
      provider = template[:provider].to_sym
      expect(Agent::MODELS.keys).to include(provider), "#{template[:slug]} has unknown provider"
      expect(Agent::MODELS[provider]).to include(template[:model]), "#{template[:slug]} has bad model"
    end
    # google is deliberately absent: it has no verified Agent::MODELS entry, so
    # no template may promise it (the enum exists, the runnable list does not).
    expect(described_class.all.map { |t| t[:provider] }).not_to include("google")
  end

  it "uses unique url-safe slugs" do
    slugs = described_class.all.map { |template| template[:slug] }
    expect(slugs.uniq.size).to eq(slugs.size)
    expect(slugs).to all(match(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/))
  end

  it "advertises only tools this install can run" do
    described_class.all.each do |template|
      template[:tools].each do |name|
        resolved = Agents::ToolRegistry.get(name).present? || Tools::Catalog.catalog_tool?(name)
        expect(resolved).to be(true), "template #{template[:slug]} advertises #{name.inspect}"
      end
    end
  end

  it "builds a valid persisted-ready agent for every template" do
    organization = create(:organization)
    described_class.all.each do |template|
      agent = described_class.to_agent(template, organization: organization)
      expect(agent).to be_valid, "#{template[:slug]} is not a valid agent"
    end
  end

  describe ".find" do
    it "locates a template by exact slug" do
      expect(described_class.find("code-writer")[:name]).to eq("Code Writer")
    end

    it "returns nil for unknown or blank slugs" do
      expect(described_class.find("not-a-template")).to be_nil
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
    end
  end

  describe ".available" do
    it "lists every template because this install runs all advertised tools" do
      expect(described_class.available).to eq(described_class.all)
    end

    it "hides any template whose tools stop resolving" do
      allow(Agents::ToolRegistry).to receive(:get).and_return(nil)
      allow(Tools::Catalog).to receive(:catalog_tool?).and_return(false)

      expect(described_class.available.map { |t| t[:slug] })
        .to contain_exactly("arabic-english-translator", "email-drafter", "meeting-notes")
      expect(described_class.runnable?(described_class.find("image-artist"))).to be(false)
    end
  end

  describe ".categories" do
    it "returns sorted unique categories" do
      categories = described_class.categories
      expect(categories).to eq(categories.uniq.sort)
      expect(categories).to include("Creative", "Development", "Language")
    end
  end

  describe ".search" do
    it "filters by category" do
      expect(described_class.search(category: "Creative").map { |t| t[:name] }).to eq([ "Image Artist" ])
    end

    it "matches name or description, case-insensitively" do
      expect(described_class.search(query: "TRANSLAT").map { |t| t[:slug] }).to eq([ "arabic-english-translator" ])
      expect(described_class.search(query: " csv ").map { |t| t[:slug] }).to eq([ "data-analyst" ])
    end

    it "combines filters and returns the whole catalog when both are blank" do
      expect(described_class.search(query: "", category: "")).to eq(described_class.all)
      expect(described_class.search(query: "code", category: "Creative")).to be_empty
      expect(described_class.search).to eq(described_class.all)
    end
  end

  describe ".to_agent" do
    it "builds an unsaved agent inside the given organization" do
      organization = create(:organization)
      template = described_class.find("research-assistant")
      agent = described_class.to_agent(template, organization: organization)

      expect(agent).not_to be_persisted
      expect(organization.agents.count).to eq(0)
      expect(agent.organization).to eq(organization)
      expect([ agent.name, agent.slug, agent.provider, agent.model ])
        .to eq([ template[:name], template[:slug], template[:provider], template[:model] ])
      expect(agent.tools).to eq(template[:tools])
      expect(agent.is_active).to be(true)
    end

    it "copies tools so mutating an agent never rewrites the frozen catalog" do
      template = described_class.find("code-writer")
      agent = described_class.to_agent(template, organization: create(:organization))

      built = agent.tools
      expect(built).not_to be(template[:tools])
      built << "calculator"
      expect(template[:tools]).to eq([ "code_executor", "write_file" ])
    end
  end
end
