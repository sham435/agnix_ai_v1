# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe WebfetchService, type: :service do
  subject(:service) { described_class }

  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:url) { "https://example.test/page" }
  let(:public_address) { "93.184.216.34" }

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  before do
    allow(Resolv).to receive(:getaddresses).with("example.test").and_return([ public_address ])
    allow(Resolv).to receive(:getaddresses).with("redirect.test").and_return([ public_address ])
    Rails.cache.clear
  end

  def fetch(url: self.url, format: "markdown", timeout: 20, acting_user: user, org: organization, cancelled: nil)
    service.call(url: url, format: format, timeout: timeout, user: acting_user, organization: org, cancelled: cancelled)
  end

  def stub_page(body: "<p>Hello</p>", content_type: "text/html", status: 200, headers: {})
    stub_request(:get, url).to_return(status: status, body: body, headers: { "Content-Type" => content_type }.merge(headers))
  end

  describe "successful extraction" do
    it "returns bounded untrusted HTML-derived markdown and strips active content" do
      stub_page(body: <<~HTML)
        <h1>Heading</h1><script>alert(1)</script><style>bad{}</style>
        <p onclick="evil()">Hello <strong>world</strong><a href="javascript:alert(1)" onmouseover="x()">bad</a>
        <a href="/safe?q=1" title="ok">safe</a><img src="https://inner.test/x"><iframe src="x"></iframe></p>
      HTML

      result = fetch

      expect(result).to include(ok: true, format: "markdown", final_url: url, untrusted: true, truncated: false)
      expect(result[:content]).to include("# Heading", "Hello **world**", "[safe](https://example.test/safe?q=1)")
      expect(result[:content]).not_to include("script", "alert", "onclick", "iframe", "javascript:", "<img")
    end

    it "supports sanitized HTML and plain-text output formats" do
      stub_page(body: "<p>A &amp; B</p>")

      html = fetch(format: "html")
      text = fetch(format: "text")

      expect(html[:content]).to include("<p>A &amp; B</p>")
      expect(text[:content]).to eq("A & B")
    end

    it "extracts plain text, JSON, XML, and safe Markdown MIME types" do
      stub_page(body: "plain", content_type: "text/plain")
      expect(fetch(format: "text")[:content]).to eq("plain")

      stub_page(body: '{"answer":42}', content_type: "application/json")
      expect(fetch[:content]).to include('"answer":42')

      stub_page(body: "<root><answer>42</answer></root>", content_type: "application/xml")
      expect(fetch[:content]).to include("<answer>42</answer>")

      stub_page(body: "# Title\n\n**bold**", content_type: "text/markdown")
      markdown = fetch
      expect(markdown[:content]).to start_with("# Title")
      expect(markdown[:content]).to include("**bold**")
    end

    it "does not render raw HTML or dangerous links from source Markdown" do
      stub_page(body: "# Safe\n\n<script>alert(1)</script>\n\n[bad](javascript:alert(1))", content_type: "text/markdown")

      result = fetch

      expect(result[:content]).not_to include("<script", "javascript:")
      expect(result[:content]).to include("# Safe")
    end

    it "strictly decodes an allowlisted legacy charset" do
      stub_page(body: "caf\xE9".b, content_type: "text/plain; charset=windows-1252")

      result = fetch(format: "text")

      expect(result[:content]).to eq("café")
      expect(result[:content].encoding).to eq(Encoding::UTF_8)
    end

    it "sniffs textual content when Content-Type is absent" do
      stub_page(body: '{"sniffed":true}', content_type: nil)

      result = fetch

      expect(result[:content_type]).to eq("application/json")
      expect(result[:content]).to include('"sniffed":true')
    end
  end

  describe "URL and SSRF policy" do
    it "rejects non-HTTP schemes, userinfo, controls, backslashes, relative URLs, and oversized URLs before DNS" do
      invalid_urls = [
        "file:///etc/passwd", "ftp://example.test/x", "https://user:pass@example.test/x",
        "https://example.test/%0d%0a", "https://example.test/a\\b", "/relative"
      ]
      allow(Resolv).to receive(:getaddresses).and_call_original

      invalid_urls.each do |invalid_url|
        expect(fetch(url: invalid_url)[:error_code]).to eq("url_invalid")
      end
      expect(fetch(url: "https://#{'a' * 2_049}.test")[:error_code]).to eq("invalid_request")
      expect(Resolv).not_to have_received(:getaddresses)
      expect(a_request(:get, /example\.test/)).not_to have_been_made
    end

    it "rejects private, loopback, link-local, shared, documentation, multicast, and reserved IPv4 literals" do
      addresses = %w[0.0.0.0 10.1.2.3 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1
                     192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1 203.0.113.1 224.0.0.1 240.0.0.1]

      addresses.each do |address|
        expect(fetch(url: "http://#{address}/")[:error_code]).to eq("url_forbidden")
      end
      expect(a_request(:get, /./)).not_to have_been_made
    end

    it "rejects loopback, link-local, ULA, multicast, mapped, NAT64, documentation, and transition IPv6 addresses" do
      addresses = %w[::1 ::ffff:127.0.0.1 fe80::1 fc00::1 ff02::1 64:ff9b::7f00:1
                     2001:db8::1 2001::1 2002:7f00:1:: 3fff::1]

      addresses.each do |address|
        expect(fetch(url: "http://[#{address}]/")[:error_code]).to eq("url_forbidden")
      end
      expect(a_request(:get, /./)).not_to have_been_made
    end

    it "rejects the hostname if any DNS answer is forbidden" do
      allow(Resolv).to receive(:getaddresses).with("example.test").and_return([ public_address, "127.0.0.1" ])

      result = fetch

      expect(result[:error_code]).to eq("url_forbidden")
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "returns a sanitized DNS failure without making a request" do
      allow(Resolv).to receive(:getaddresses).with("example.test").and_raise(Resolv::ResolvError, "secret resolver detail")

      result = fetch

      expect(result[:error_code]).to eq("dns_failed")
      expect(result[:error]).not_to include("secret", "example.test")
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "pins the validated address while preserving the hostname used for Host and TLS SNI" do
      captured = nil
      allow(HTTParty).to receive(:get).and_wrap_original do |original, request_url, **options, &block|
        connection = options.fetch(:connection_adapter).call(URI.parse(request_url), options)
        captured = { address: connection.address, ipaddr: connection.ipaddr, port: connection.port }
        original.call(request_url, **options, &block)
      end
      stub_page(body: "ok", content_type: "text/plain")

      expect(fetch[:ok]).to be true
      expect(captured).to eq(address: "example.test", ipaddr: public_address, port: 443)
      expect(Resolv).to have_received(:getaddresses).with("example.test").once
    end

    it "bypasses inherited proxy environment variables for the pinned request" do
      keys = %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy]
      original_env = ENV.to_hash
      keys.each { |key| ENV[key] = "http://127.0.0.1:9" }
      captured_proxy = nil
      allow(HTTParty::ConnectionAdapter).to receive(:call).and_wrap_original do |original, request_uri, options|
        captured_proxy = options[:http_proxyaddr]
        original.call(request_uri, options)
      end
      stub_page(body: "direct", content_type: "text/plain")

      expect(fetch(format: "text")).to include(ok: true, content: "direct")
      expect(captured_proxy).to be_nil
      expect(a_request(:get, url)).to have_been_made.once
    ensure
      ENV.replace(original_env)
    end
  end

  describe "redirects" do
    it "manually follows and revalidates a relative public redirect" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "/next" })
      stub_request(:get, "https://example.test/next").to_return(status: 200, body: "done", headers: { "Content-Type" => "text/plain" })

      result = fetch

      expect(result).to include(ok: true, final_url: "https://example.test/next")
      expect(a_request(:get, "https://example.test/next")).to have_been_made.once
    end

    it "rejects a redirect to a private destination without requesting it" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://127.0.0.1/private" })

      result = fetch

      expect(result[:error_code]).to eq("url_forbidden")
      expect(a_request(:get, "https://127.0.0.1/private")).not_to have_been_made
    end

    it "classifies a prohibited HTTP redirect from HTTPS as url_forbidden" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://127.0.0.1/private" })

      result = fetch

      expect(result[:error_code]).to eq("url_forbidden")
      expect(a_request(:get, "http://127.0.0.1/private")).not_to have_been_made
    end

    it "applies destination policy before downgrade policy for a private redirect hostname" do
      allow(Resolv).to receive(:getaddresses).with("redirect.test").and_return([ "127.0.0.1" ])
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://redirect.test/private" })

      result = fetch

      expect(result[:error_code]).to eq("url_forbidden")
      expect(a_request(:get, "http://redirect.test/private")).not_to have_been_made
    end

    it "forbids HTTPS-to-HTTP downgrades" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://example.test/plain" })

      result = fetch

      expect(result[:error_code]).to eq("downgrade_forbidden")
      expect(a_request(:get, "http://example.test/plain")).not_to have_been_made
    end

    it "rejects malformed, missing, and excessive redirects with stable errors" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://user:pass@redirect.test/x" })
      expect(fetch[:error_code]).to eq("redirect_invalid")

      stub_request(:get, url).to_return(status: 302, body: "")
      expect(fetch[:error_code]).to eq("redirect_invalid")

      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://redirect.test/loop" })
      stub_request(:get, "https://redirect.test/loop").to_return(status: 302, headers: { "Location" => "/loop" })
      expect(fetch[:error_code]).to eq("too_many_redirects")
    end
  end

  describe "deadline, size, and content safety" do
    it "uses one initial monotonic clock read and stops before HTTP when the total deadline elapses" do
      now = 100.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      transport = described_class::Transport.new(timeout: 1)
      expect(Process).to have_received(:clock_gettime).with(Process::CLOCK_MONOTONIC).once

      allow(described_class::Transport).to receive(:new).and_return(transport)
      now = 101.0
      result = fetch(timeout: 1)

      expect(result[:error_code]).to eq("timeout")
      expect(Resolv).not_to have_received(:getaddresses)
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "honors cancellation before DNS or HTTP" do
      result = fetch(cancelled: -> { true })

      expect(result[:error_code]).to eq("cancelled")
      expect(Resolv).not_to have_received(:getaddresses)
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "rejects an oversized declared Content-Length" do
      stub_page(body: "small", content_type: "text/plain", headers: { "Content-Length" => (2.megabytes + 1).to_s })

      expect(fetch[:error_code]).to eq("response_too_large")
    end

    it "rejects actual streamed bytes over the cap before appending the oversized fragment" do
      allow(HTTParty).to receive(:get) do |_request_url, _options, &block|
        block.call("x" * 1.megabyte)
        block.call("x" * (1.megabyte + 1))
        double(code: 200, headers: { "Content-Type" => "text/plain" }, body: "")
      end

      expect(fetch[:error_code]).to eq("response_too_large")
    end

    it "bounds fallback response bodies even when a client does not stream fragments" do
      allow(HTTParty).to receive(:get).and_return(double(code: 200, headers: { "Content-Type" => "text/plain" }, body: "x" * (2.megabytes + 1)))

      expect(fetch[:error_code]).to eq("response_too_large")
    end

    it "rejects unsupported MIME types, malformed JSON/XML, DTDs, invalid encoding, and malformed charsets" do
      stub_page(body: "%PDF-1.7", content_type: "application/pdf")
      expect(fetch[:error_code]).to eq("unsupported_content_type")

      stub_page(body: "{bad", content_type: "application/json")
      expect(fetch[:error_code]).to eq("invalid_content")

      stub_page(body: "<root>", content_type: "application/xml")
      expect(fetch[:error_code]).to eq("invalid_content")

      stub_page(body: '<!DOCTYPE root [<!ENTITY x "expanded">]><root>&x;</root>', content_type: "application/xml")
      expect(fetch[:error_code]).to eq("invalid_content")

      stub_page(body: "\xFF".b, content_type: "text/plain; charset=utf-8")
      expect(fetch[:error_code]).to eq("invalid_content")

      stub_page(body: "ok", content_type: "text/plain; charset=unknown-made-up")
      expect(fetch[:error_code]).to eq("invalid_content")

      stub_page(body: "ok", content_type: "text/plain; charset")
      expect(fetch[:error_code]).to eq("invalid_content")
    end

    it "enforces DOM depth and node bounds" do
      stub_page(body: "<div>" * 102 + "deep" + "</div>" * 102)
      expect(fetch[:error_code]).to eq("unsafe_dom")

      stub_page(body: "<span>x</span>" * 20_001)
      expect(fetch[:error_code]).to eq("unsafe_dom")
    end

    it "caps output bytes after HTML escaping and reports truncation" do
      stub_page(body: "&" * 300_000, content_type: "text/plain")

      result = fetch(format: "html")

      expect(result[:ok]).to be true
      expect(result[:truncated]).to be true
      expect(result[:content].bytesize).to be <= described_class::MAX_OUTPUT_BYTES
    end

    it "keeps truncated multibyte output within the byte cap without replacement-character growth" do
      stub_page(body: "界" * 100_000, content_type: "text/plain")

      result = fetch(format: "text")

      expect(result[:ok]).to be true
      expect(result[:truncated]).to be true
      expect(result[:content].bytesize).to be <= described_class::MAX_OUTPUT_BYTES
      expect(result[:content]).to be_valid_encoding
    end

    it "returns stable sanitized HTTP and network errors" do
      stub_page(body: "secret upstream body", content_type: "text/plain", status: 503)
      http_result = fetch
      expect(http_result[:error_code]).to eq("http_error")
      expect(http_result[:error]).not_to include("secret", "example.test")

      stub_request(:get, url).to_raise(SocketError, "secret socket detail")
      network_result = fetch
      expect(network_result[:error_code]).to eq("network_error")
      expect(network_result[:error]).not_to include("secret", "example.test")
    end
  end

  describe "authorization and abuse control" do
    it "denies missing or foreign actors before DNS or HTTP" do
      expect(fetch(acting_user: nil)[:error_code]).to eq("not_authorized")
      expect(fetch(org: nil)[:error_code]).to eq("not_authorized")
      expect(fetch(acting_user: create(:user))[:error_code]).to eq("not_authorized")
      expect(Resolv).not_to have_received(:getaddresses)
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "enforces an organization capability disable before DNS or HTTP" do
      organization.update!(settings: { "capabilities" => { "webfetch" => false } })

      expect(fetch[:error_code]).to eq("capability_unavailable")
      expect(Resolv).not_to have_received(:getaddresses)
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "enforces the per-user cache counter" do
      allow(Rails.cache).to receive(:increment).and_return(21)

      expect(fetch[:error_code]).to eq("rate_limited")
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "enforces the per-organization cache counter after a successful user increment" do
      allow(Rails.cache).to receive(:increment).and_return(1, 61)

      expect(fetch[:error_code]).to eq("rate_limited")
      expect(Rails.cache).to have_received(:increment).twice
      expect(a_request(:get, url)).not_to have_been_made
    end

    it "fails closed when a later abuse-control increment is nil" do
      allow(Rails.cache).to receive(:increment).and_return(1, nil)

      expect(fetch[:error_code]).to eq("abuse_control_unavailable")
      expect(Rails.cache).to have_received(:increment).twice
      expect(a_request(:get, url)).not_to have_been_made
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
