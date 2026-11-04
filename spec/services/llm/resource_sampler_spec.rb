# frozen_string_literal: true

require "rails_helper"

RSpec.describe Llm::ResourceSampler do
  def darwin!
    allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin25.0")
  end

  def stub_reads(swap:, pressure:, rss:)
    sampler = described_class.new
    allow(sampler).to receive(:read).with(described_class::SWAP_CMD).and_return(swap)
    allow(sampler).to receive(:read).with(described_class::PRESSURE_CMD).and_return(pressure)
    allow(sampler).to receive(:read).with(described_class::RSS_CMD).and_return(rss)
    allow(described_class).to receive(:new).and_return(sampler)
    sampler
  end

  it "returns an empty sample for cloud providers (nothing to serialize)" do
    expect(described_class.sample(provider: "anthropic", model: "claude")).to eq({})
    expect(described_class.sample(provider: "openai", model: "gpt")).to eq({})
  end

  it "returns an empty sample on a non-darwin host where the probes differ" do
    allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("linux6.5")
    expect(described_class.sample(provider: "bonsai", model: "bonsai-2-27b")).to eq({})
  end

  it "parses swap, memory pressure and llama RSS into a structured sample" do
    darwin!
    stub_reads(
      swap: "total = 8192.00M  used = 7102.69M  free = 1089.31M",
      pressure: "System-wide memory free percentage: 41%",
      rss: "  204800 /Users/sham4/bonsai227b/bin/mac/llama-server -m ...\n  102400 /Applications/Ollama.app/Contents/Resources/llama-server\n"
    )

    expect(described_class.sample(provider: "bonsai", model: "bonsai-2-27b")).to eq(
      swap_used_mb: 7102.7,
      memory_free_pct: 41.0,
      llama_rss_mb: 300.0
    )
  end

  it "omits a metric whose probe returns nothing instead of guessing" do
    darwin!
    stub_reads(swap: nil, pressure: "no percentage here", rss: "")

    expect(described_class.sample(provider: "ollama", model: "x")).to eq({})
  end

  it "never raises when a read blows up" do
    darwin!
    sampler = described_class.new
    allow(sampler).to receive(:read).and_raise(Errno::ENOENT)
    allow(described_class).to receive(:new).and_return(sampler)

    expect { described_class.sample(provider: "bonsai", model: "x") }.not_to raise_error
  end
end
