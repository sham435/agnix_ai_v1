# frozen_string_literal: true

require "rails_helper"

# Contract examples assert related evidence and safety invariants together.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe Research::DeepResearch, type: :service do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:source) { { title: "Evidence", url: "https://example.com/a#one", snippet: "Observed evidence" } }

  before do
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("test-key")
    stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .to_return(body: { results: [ { title: source[:title], url: source[:url], content: source[:snippet] } ] }.to_json)
  end

  def research(**options)
    described_class.call(topic: "Rails", user: user, organization: organization, **options)
  end

  it "makes deterministic real searches and deduplicates fragment URLs" do
    result = research(questions: [ "Why Rails?" ])
    expect(result[:status]).to eq("completed")
    expect(result[:calls].pluck(:query)).to eq([ "Rails", "Why Rails?", "Rails evidence", "Rails limitations" ])
    expect(result[:sources].pluck(:url)).to eq([ "https://example.com/a" ])
    expect(result[:findings]).to eq([ { text: "Observed evidence", source_url: "https://example.com/a", basis: "search_snippet" } ])
  end

  it "rejects missing authorization before any search" do
    expect(described_class.call(topic: "Rails", user: nil, organization: organization)).to include(status: "error", reason: "not_authorized", calls: [])
  end

  it "rejects a different organization's user" do
    stranger = create(:organization).owner
    expect(described_class.call(topic: "Rails", user: stranger, organization: organization)).to include(reason: "not_authorized", calls: [])
  end

  it "rejects an incorrectly scoped integration" do
    other = create(:tool_integration, organization: create(:organization), provider: "web_search")
    allow(ToolIntegration).to receive(:connection_for).with(organization, "web_search").and_return(other)
    expect(research).to include(reason: "not_authorized", calls: [])
  end

  it "does not fall back to a server key when the organization connection is disabled" do
    create(:tool_integration, organization: organization, provider: "web_search", is_active: false,
      credentials: { "api_key" => "disabled-key" })

    expect(research).to include(status: "error", reason: "integration_inactive", calls: [])
    expect(a_request(:post, Integrations::WebSearch::ENDPOINT)).not_to have_been_made
  end

  it "rejects missing provider keys" do
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return(nil)
    allow(Rails.application.credentials).to receive(:dig).with(:web_search, :api_key).and_return(nil)
    expect(research).to include(reason: "missing_credentials", calls: [])
  end

  it "uses encrypted organization credentials instead of the server key" do
    create(:tool_integration, organization: organization, provider: "web_search", credentials: { "api_key" => "org-key" })
    request = stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .with(headers: { "Authorization" => "Bearer org-key" }).to_return(body: { results: [] }.to_json)
    expect(research[:status]).to eq("completed")
    expect(request).to have_been_requested.times(3)
  end

  it "uses the server key when an active organization integration has a blank key" do
    create(:tool_integration, organization: organization, provider: "web_search", credentials: { "api_key" => " " })
    request = stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .with(headers: { "Authorization" => "Bearer test-key" }).to_return(body: { results: [] }.to_json)

    expect(research[:status]).to eq("completed")
    expect(request).to have_been_requested.times(3)
  end

  it "canonicalizes citation URLs and rejects unsafe or malformed targets" do
    expect(described_class.canonical_url("HTTPS://EXAMPLE.COM/a#one")).to eq("https://example.com/a")
    expect(described_class.canonical_url("http://example.com")).to eq("http://example.com/")
    [ "javascript:alert(1)", "https://user:pass@example.com/a", "https://example.com\\@evil.test/a",
      "https://example.com/\npath", "https://example.com:bad/a" ].each do |url|
      expect(described_class.canonical_url(url)).to be_nil
    end
  end

  it "returns a compact numbered ledger whose findings reference source ids" do
    result = research
    tool_result = described_class.tool_result(result)
    source_id = described_class.source_id("https://example.com/a")

    expect(tool_result[:sources]).to eq([
      { source_id: source_id, title: "Evidence", url: "https://example.com/a", snippet: "Observed evidence", number: 1 }
    ])
    expect(tool_result[:findings]).to eq([ { source_id: source_id, basis: "search_snippet" } ])
    expect(tool_result[:calls]).to eq(3)
    expect(tool_result[:omitted_sources]).to eq(0)
    expect(tool_result.to_json.bytesize).to be <= described_class::TOOL_RESULT_MAX_BYTES
    expect(result[:sources].first[:snippet]).to eq("Observed evidence")
  end

  it "bounds oversized tool ledgers without altering the full service result" do
    sources = 10.times.map do |index|
      url = "https://example.com/#{index}/#{"a" * 400}"
      { source_id: described_class.source_id(url), title: "Evidence #{index}", url: url, snippet: "x" * 2000 }
    end
    result = {
      status: "completed", reason: nil, calls: Array.new(20) { { query: "q" } }, sources: sources,
      findings: sources.map { |entry| { text: entry[:snippet], source_url: entry[:url], basis: "search_snippet" } },
      limits: { sources: 10, calls: 20, seconds: 120, questions: 5, snippet_characters: 2000 },
      elapsed_seconds: 1.0, caveat: "Findings are provider search snippets; full pages have not been reviewed."
    }

    tool_result = described_class.tool_result(result)

    expect(tool_result[:sources].length).to be < 10
    expect(tool_result[:omitted_sources]).to be_positive
    expect(tool_result[:findings].pluck(:source_id)).to eq(tool_result[:sources].pluck(:source_id))
    expect(tool_result[:findings]).to all(satisfy { |finding| finding.keys.sort == %i[basis source_id] })
    expect(tool_result.to_json.bytesize).to be <= described_class::TOOL_RESULT_MAX_BYTES
    expect(result[:sources].length).to eq(10)
    expect(result[:sources].map { |entry| entry[:snippet].length }.uniq).to eq([ 2000 ])
  end

  it "bounds snippets and stops at the source budget" do
    responses = 4.times.map do |batch|
      results = 3.times.map { |i| { url: "https://example.com/#{batch * 3 + i}", content: "x" * 3000 } }
      { body: { results: results }.to_json }
    end
    stub_request(:post, Integrations::WebSearch::ENDPOINT).to_return(*responses)
    result = research(questions: [ "One", "Two", "Three" ])
    expect(result).to include(status: "partial", reason: "source_limit")
    expect(result[:sources].length).to eq(10)
    expect(result[:sources].pluck(:snippet).map(&:length).uniq).to eq([ 2000 ])
    expect(result[:calls].length).to eq(4)
  end

  it "stops at the call budget" do
    stub_const("Research::DeepResearch::MAX_CALLS", 1)
    expect(research).to include(status: "partial", reason: "call_limit")
  end

  it "rejects excessive questions" do
    expect(research(questions: Array.new(6, "question"))).to include(reason: "invalid_request", calls: [])
  end

  it "cancels before requests" do
    expect(research(cancelled: -> { true })).to include(status: "cancelled", calls: [])
  end

  it "cancels between requests preserving retrieved evidence" do
    checks = 0
    result = research(cancelled: -> { checks += 1; checks >= 3 })
    expect(result[:status]).to eq("cancelled")
    expect(result[:calls].length).to eq(1)
    expect(result[:sources].length).to eq(1)
  end

  it "checks elapsed monotonic time before starting a request" do
    user
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0, 121)
    expect(research).to include(status: "partial", reason: "time_limit", calls: [])
  end

  it "bounds each invocation by the remaining deadline" do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(research[:status]).to eq("completed")
    expect(Timeout).to have_received(:timeout).with(be_between(0, 120)).at_least(:once)
  end

  it "reports deadline expiration even when the adapter returns an error" do
    allow(Integrations::WebSearch).to receive(:call) do
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(1000)
      { ok: false, error_code: "provider_error" }
    end
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0)
    expect(research).to include(status: "partial", reason: "time_limit")
  end

  it "returns a sanitized error without evidence on provider failure" do
    stub_request(:post, Integrations::WebSearch::ENDPOINT).to_return(status: 500, body: "secret")
    expect(research).to include(status: "error", reason: "provider_error", sources: [])
  end

  it "preserves evidence when a later request fails" do
    stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .to_return(body: { results: [ { url: source[:url], content: source[:snippet] } ] }.to_json)
      .then.to_return(status: 500)
    result = research
    expect(result).to include(status: "partial", reason: "provider_error")
    expect(result[:sources].length).to eq(1)
  end
end
