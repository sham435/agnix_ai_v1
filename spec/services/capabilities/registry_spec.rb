# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Capabilities::Registry do
  it "exposes typed entries for every capability with honest states" do
    keys = described_class.index.map { |e| e[:key] }
    expect(keys).to include("chat", "attachments", "library", "file_extraction", "thinking", "web_search", "deep_research", "image_generation", "sketch")

    described_class.index.each do |entry|
      expect(entry[:label]).to be_present
      expect(entry[:input_schema]).to be_a(Hash)
      expect(entry[:output_schema]).to be_a(Hash)
      expect(entry[:execution_limits]).to be_a(Hash)
      expect(entry[:async]).to be_in([ true, false ])
      expect(Capabilities::Registry::STATES.map(&:to_s)).to include(entry[:state].to_s)
    end
  end

  it "reports unconfigured external providers honestly" do
    web_search = described_class.find("web_search")
    expect(web_search[:state].to_s).to be_in(%w[enabled needs_authorization])

    deep_research = described_class.find("deep_research")
    expect(deep_research[:state].to_s).to be_in(%w[enabled disabled needs_authorization])
    expect(described_class.find("image_generation")[:state].to_s).to eq("needs_authorization")
    expect(described_class.find("sketch")[:state].to_s).to eq("disabled")
  end

  it "becomes enabled when the web search provider is configured (ENV gate)" do
    blk = described_class.method(:web_search_configured?)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("dryv")
    expect(blk.call).to be true
    expect(described_class.find("deep_research")[:state].to_s).to eq("enabled")
  end

  it "becomes enabled for image_generation once an OpenAI image key exists (ENV gate)" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("sk-phase3-test")

    expect(described_class.openai_image_key_configured?).to be(true)
    expect(described_class.find("image_generation")[:state].to_s).to eq("enabled")
    expect(described_class.available?("image_generation")).to be(true)
  end

  it "available? is strictly state-based" do
    expect(described_class.available?("chat")).to be true
    expect(described_class.available?("sketch")).to be false
  end

  it "validates input against the typed schema and rejects unknown keys" do
    expect(described_class.validate_input("thinking", { "effort" => "low" })).to be_empty
    expect(described_class.validate_input("thinking", { "effort" => "turbo" })).to be_present

    expect { described_class.validate_input("teleport_user", {}) }
      .to raise_error(Capabilities::Registry::UnknownCapability)
    expect { described_class.find("unknown_key") }
      .to raise_error(Capabilities::Registry::UnknownCapability)
  end
end
