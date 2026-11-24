# frozen_string_literal: true

require "rails_helper"

# Contract scenarios intentionally verify several related security invariants.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/SpecFilePathFormat
RSpec.describe Integrations::WebSearch, type: :service do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:search) { create(:tool_integration, organization: organization, provider: "web_search", credentials: { "api_key" => "tvly-test" }) }
  let(:figma) { create(:tool_integration, organization: organization, provider: "figma", credentials: { "api_key" => "fig-test" }) }

  def search_call(args = { "query" => "Rails" })
    Integrations::WebSearch.call(integration: search, arguments: args)
  end

  def figma_call(args = { "file_key" => "abc123" })
    Integrations::FigmaGetFile.call(integration: figma, arguments: args)
  end

  it "returns only actual safe provider sources through native org credentials" do
    search
    stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .with(headers: { "Authorization" => "Bearer tvly-test" }, body: hash_including("query" => "Rails", "max_results" => 5))
      .to_return(body: { results: [ { title: "Rails", url: "https://rubyonrails.org/", content: "News" },
                                    { url: "javascript:alert(1)" }, { url: "https://user:pass@example.com" }, {} ] }.to_json)
    result = Agents::ToolRegistry.execute("web_search", { "query" => "Rails" }, user: user, organization: organization)
    expect(result).to include(ok: true, sources: [ { title: "Rails", url: "https://rubyonrails.org/", snippet: "News" } ])
    expect(search.reload.last_used_at).to be_present
  end

  it "supports the existing server key for an authorized user" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("tvly-server")
    stub_request(:post, Integrations::WebSearch::ENDPOINT).with(headers: { "Authorization" => "Bearer tvly-server" })
      .to_return(body: { results: [] }.to_json)
    expect(Agents::ToolRegistry.execute("web_search", { "query" => "Rails" }, user: user, organization: organization)).to include(ok: true)
  end

  it "uses the server key when an active organization integration has a blank key" do
    search.update!(credentials: { "api_key" => " " })
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("tvly-server")
    request = stub_request(:post, Integrations::WebSearch::ENDPOINT)
      .with(headers: { "Authorization" => "Bearer tvly-server" }).to_return(body: { results: [] }.to_json)

    result = described_class.call(integration: search, arguments: { "query" => "Rails" }, api_key: "tvly-server")
    expect(result).to include(ok: true)
    expect(request).to have_been_requested.once
  end

  it "rejects invalid search bounds without HTTP" do
    [ { "query" => " " }, { "query" => "x" * 513 }, { "query" => "Rails", "num_results" => 11 },
      { "query" => "Rails", "max_results" => 0 } ].each do |args|
      expect(search_call(args)).to include(ok: false, error_code: "invalid_request")
    end
    assert_not_requested(:post, Integrations::WebSearch::ENDPOINT)
  end

  it "rejects missing and unsafe keys for both providers" do
    [ search, figma ].each do |row|
      row.update!(credentials: {})
      adapter = row.provider == "figma" ? Integrations::FigmaGetFile : described_class
      args = row.provider == "figma" ? { "file_key" => "abc" } : { "query" => "Rails" }
      expect(adapter.call(integration: row, arguments: args)).to include(error_code: "missing_credentials")
      row.update!(credentials: { "api_key" => "bad\nkey" })
      expect(adapter.call(integration: row, arguments: args)).to include(error_code: "invalid_credentials")
    end
  end

  it "rejects disabled integrations on direct and native execution without HTTP" do
    search.update!(is_active: false)
    figma.update!(is_active: false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SHAMS_WEB_SEARCH_API_KEY").and_return("server-key")

    expect(Agents::ToolRegistry.execute("web_search", { "query" => "Rails" }, user: user, organization: organization))
      .to eq(ok: false, error_code: "capability_unavailable", capability: "web_search")
    expect(search_call).to eq(ok: false, error_code: "integration_inactive")
    expect(figma_call).to eq(ok: false, error_code: "integration_inactive")
    assert_not_requested(:post, Integrations::WebSearch::ENDPOINT)
    assert_not_requested(:get, "https://api.figma.com/v1/files/abc123?depth=2")
  end

  it "reads Figma using only the fixed GET endpoint and bounded depth" do
    stub = stub_request(:get, "https://api.figma.com/v1/files/abc123?depth=2")
      .with(headers: { "X-Figma-Token" => "fig-test" })
      .to_return(body: { name: "Design", document: { type: "DOCUMENT" } }.to_json)
    expect(figma_call).to include(ok: true, result: { "name" => "Design", "document" => { "type" => "DOCUMENT" } })
    expect(stub).to have_been_requested.once
    expect(Tools::Catalog.tool_schemas_for("figma").map { |tool| tool[:name] }).to eq([ "figma.get_file" ])
  end

  it "rejects file URLs, traversal, query injection and excessive depth" do
    [ "../secret", "https://figma.com/file/abc", "abc?x=y", "abc\n", "x" * 129 ].each do |key|
      expect(figma_call("file_key" => key)).to include(error_code: "invalid_request")
    end
    expect(figma_call("file_key" => "abc", "depth" => 6)).to include(error_code: "invalid_request")
  end

  it "sanitizes failures, malformed JSON, redirects, timeouts and oversized responses" do
    [ [ 401, "tvly-test fig-test" ], [ 500, "secret" ], [ 302, "redirect" ], [ 200, "not json" ],
      [ 200, "x" * (Integrations::BoundedJsonRequest::MAX_BYTES + 1) ] ].each do |status, body|
      stub_request(:post, Integrations::WebSearch::ENDPOINT).to_return(status: status, body: body)
      stub_request(:get, "https://api.figma.com/v1/files/abc123?depth=2").to_return(status: status, body: body)
      expect(search_call).to eq(ok: false, error_code: "provider_error")
      expect(figma_call).to eq(ok: false, error_code: "provider_error")
    end
    stub_request(:post, Integrations::WebSearch::ENDPOINT).to_timeout
    expect(search_call).to eq(ok: false, error_code: "provider_error")
  end

  it "scopes capability states and dispatcher connections to the organization" do
    search
    figma
    other = create(:organization)
    expect(Capabilities::Registry.available?("web_search", organization: organization)).to be(true)
    expect(Capabilities::Registry.find("figma", organization: organization)[:state]).to eq("enabled")
    expect(Capabilities::Registry.find("figma", organization: other)[:state]).to eq("needs_authorization")
    expect(Tools::Dispatcher.call("figma.get_file", arguments: { "file_key" => "abc" }, organization: other, integration_id: figma.id)).to include(error_code: "not_connected")
    expect(Tools::Dispatcher.call("web_search.search", arguments: { "query" => "Rails" }, organization: other, integration_id: search.id)).to include(error_code: "not_connected")
    search.update!(is_active: false)
    expect(Capabilities::Registry.connection_configured?(organization, "web_search")).to be(false)
  end

  it "rejects acting users from another organization even with forged context" do
    stranger = create(:user)
    search
    figma
    result = Agents::ToolRegistry.execute("web_search", { "query" => "Rails" }, user: stranger, organization: organization)
    expect(result[:ok]).to be(false)
    expect(Integrations::FigmaGetFile.call(integration: figma, arguments: { "file_key" => "abc" }, context: { user: stranger, organization: organization })).to include(error_code: "not_authorized")
    assert_not_requested(:post, Integrations::WebSearch::ENDPOINT)
  end
end
