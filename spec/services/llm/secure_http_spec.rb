# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe Llm::SecureHttp do
  subject(:http) { described_class }

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:url) { "https://custom.example.test/v1/chat/completions" }
  let(:config) do
    {
      "base_url" => "https://custom.example.test/v1", "auth_mode" => "bearer",
      "open_timeout" => 4, "read_timeout" => 17, "max_retries" => 0
    }
  end
  let(:credentials) { { "api_key" => "test-only-provider-key", "secret_headers" => {} } }
  let(:integration) do
    instance_double(ToolIntegration, config: config, api_key: credentials["api_key"],
                                    decrypted_credentials: credentials)
  end
  let(:connection) do
    Llm::ProviderConnection.new(provider: "custom-acme", integration: integration, model: "test-model")
  end

  before do
    # Destination policy has its own focused specs; isolate transport behavior from DNS.
    allow(Llm::ProviderEndpoint).to receive(:enforce_destination!)
  end

  it "passes bounded timeouts and disables redirects and non-streaming mode" do
    captured = nil
    allow(HTTParty).to receive(:post).and_wrap_original do |original, request_url, **options|
      captured = options
      original.call(request_url, **options)
    end
    stub_request(:post, url).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

    http.post(connection, "chat/completions", body: { model: "test-model" })

    expect(captured).to include(timeout: 17, open_timeout: 4, follow_redirects: false, stream_body: false)
    expect(captured[:headers]).to include("Authorization" => "Bearer test-only-provider-key")
    expect(a_request(:post, url).with(body: { model: "test-model" }.to_json)).to have_been_made.once
  end

  it "explicitly bypasses inherited environment proxies" do
    proxy_keys = %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy]
    previous_values = proxy_keys.to_h { |key| [ key, ENV[key] ] }
    proxy_keys.each { |key| ENV[key] = "http://inherited-proxy.example.test:8080" }
    captured = nil
    allow(HTTParty).to receive(:post).and_wrap_original do |original, request_url, **options|
      captured = options
      original.call(request_url, **options)
    end
    stub_request(:post, url).to_return(status: 200, body: "{}")

    http.post(connection, "chat/completions", body: { model: "test-model" })

    expect(captured[:http_proxyaddr]).to be_nil
  ensure
    previous_values&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  it "pins the validated DNS address without resolving the hostname again" do
    allow(Llm::ProviderEndpoint).to receive(:enforce_destination!).and_call_original
    allow(Resolv).to receive(:getaddresses).with("custom.example.test").once.and_return([ "93.184.216.34" ])
    captured_ip = nil
    allow(HTTParty).to receive(:post) do |request_url, **options|
      adapter = options.fetch(:connection_adapter)
      captured_ip = adapter.call(URI.parse(request_url), options).ipaddr
      double(code: 200, headers: {}, body: "{}")
    end

    http.post(connection, "chat/completions", body: { model: "test-model" })

    expect(captured_ip).to eq("93.184.216.34")
    expect(Resolv).to have_received(:getaddresses).with("custom.example.test").once
  end

  it "pins the validated DNS address for query-bearing discovery requests" do
    allow(Llm::ProviderEndpoint).to receive(:enforce_destination!).and_call_original
    allow(Resolv).to receive(:getaddresses).with("custom.example.test").once.and_return([ "93.184.216.34" ])
    captured_ip = nil
    allow(HTTParty).to receive(:get) do |request_url, **options|
      adapter = options.fetch(:connection_adapter)
      captured_ip = adapter.call(URI.parse(request_url), options).ipaddr
      double(code: 200, headers: {}, body: "{}")
    end

    http.get(connection, "models", query: { limit: 100 })

    expect(captured_ip).to eq("93.184.216.34")
    expect(Resolv).to have_received(:getaddresses).with("custom.example.test").once
  end

  it "returns a redirect response without requesting its location" do
    redirect_url = "https://other.example.test/v1/chat/completions"
    stub_request(:post, url).to_return(status: 302, body: "redirect", headers: { "Location" => redirect_url })

    response = http.post(connection, "chat/completions", body: { model: "test-model" })

    expect(response.code).to eq(302)
    expect(a_request(:post, redirect_url)).not_to have_been_made
  end

  it "rejects a request over the byte cap before invoking HTTParty" do
    config["max_request_bytes"] = 1024
    allow(HTTParty).to receive(:post)

    expect { http.post(connection, "chat/completions", body: { messages: [ { content: "x" * 2048 } ] }) }
      .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("request_too_large") }
    expect(HTTParty).not_to have_received(:post)
  end

  it "rejects a response over the byte cap" do
    config["max_response_bytes"] = 1024
    stub_request(:post, url).to_return(status: 200, body: "x" * 2048)

    expect { http.post(connection, "chat/completions", body: { model: "test-model" }) }
      .to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("response_too_large")
        expect(error.message).not_to include("custom.example.test")
      }
  end

  it "aborts a non-streaming response during fragment transfer over the byte cap" do
    config["max_response_bytes"] = 1024
    allow(HTTParty).to receive(:post) do |_request_url, options, &block|
      expect(options[:stream_body]).to be(false)
      block.call("x" * 600)
      block.call("x" * 600)
      double(headers: {}, body: "")
    end

    expect { http.post(connection, "chat/completions", body: { model: "test-model" }) }
      .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("response_too_large") }
  end

  it "bounds accumulated stream bytes" do
    config["max_stream_bytes"] = 1024
    allow(HTTParty).to receive(:post) do |_request_url, options, &block|
      expect(options[:stream_body]).to be(true)
      block.call("x" * 600)
      block.call("x" * 600)
      double(headers: {}, body: "")
    end

    expect { http.post(connection, "chat/completions", body: { model: "test-model" }) { |_chunk| } }
      .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("response_too_large") }
  end

  it "rejects CRLF in an additional header before invoking HTTParty" do
    allow(HTTParty).to receive(:post)

    expect do
      http.perform(:post, connection, url, "{}", headers: { "X-Title" => "safe\r\nX-Injected: true" })
    end.to raise_error(Llm::ProviderError) { |error|
      expect(error.code).to eq("configuration_invalid")
      expect(error.message).not_to include("X-Injected")
    }
    expect(HTTParty).not_to have_received(:post)
  end

  it "converts timeouts to retryable sanitized provider errors" do
    stub_request(:post, url).to_timeout

    expect { http.post(connection, "chat/completions", body: { model: "test-model" }) }
      .to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("provider_timeout")
        expect(error.retryable?).to be(true)
        expect(error.message).not_to include("custom.example.test", "test-only-provider-key")
      }
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
