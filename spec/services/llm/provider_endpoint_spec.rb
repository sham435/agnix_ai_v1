# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Llm::ProviderEndpoint do
  around do |example|
    original_env = ENV.to_hash
    ENV["BONSAI2_BASE_URL"] = "http://127.0.0.1:8080/v1"
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    ENV.replace(original_env)
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  before do
    # Numeric test hosts need no DNS; named hosts must never reach the network.
    allow(Resolv).to receive(:getaddresses) { |host| [ host ] }
  end

  describe "remote endpoint policy" do
    it "requires HTTPS for a remote provider" do
      url = "http://models.example.test/v1"

      expect { described_class.validate_url!(url) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("endpoint_forbidden")
        expect(error.message).not_to include("models.example.test")
      }
    end

    it "rejects internal host suffixes before DNS resolution" do
      allow(Resolv).to receive(:getaddresses)

      expect { described_class.validate_url!("https://metadata.google.internal/v1") }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
      expect(Resolv).not_to have_received(:getaddresses)
    end

    it "bounds DNS resolution and converts deadline expiry to a typed error" do
      allow(Timeout).to receive(:timeout).with(described_class::DNS_TIMEOUT).and_raise(Timeout::Error)

      expect { described_class.validate_url!("https://slow.example.test/v1") }
        .to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("endpoint_invalid")
          expect(error.message).not_to include("slow.example.test")
        }
      expect(Timeout).to have_received(:timeout).with(described_class::DNS_TIMEOUT).once
    end

    it "converts DNS resolution failures without leaking resolver details" do
      allow(Resolv).to receive(:getaddresses).with("broken.example.test")
        .and_raise(Resolv::ResolvError, "private resolver detail")

      expect { described_class.validate_url!("https://broken.example.test/v1") }
        .to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("endpoint_invalid")
          expect(error.message).not_to include("broken.example.test", "private resolver detail")
        }
    end

    it "rejects URLs containing credentials, queries, or fragments without echoing them" do
      url = "https://user:password@models.example.test/v1?token=secret#fragment"

      expect { described_class.validate_url!(url) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("endpoint_invalid")
        expect(error.message).not_to include("password", "token=secret", "models.example.test")
      }
    end
  end

  context "with production endpoint policy" do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    {
      "loopback IPv4" => "https://127.0.0.1/v1",
      "loopback IPv6" => "https://[::1]/v1",
      "localhost" => "https://localhost/v1",
      "RFC1918 private" => "https://10.0.0.1/v1",
      "shared address space" => "https://100.64.0.1/v1",
      "link-local" => "https://169.254.10.1/v1",
      "NAT64 loopback" => "https://[64:ff9b::7f00:1]/v1",
      "IPv6 unique-local" => "https://[fd00::1]/v1",
      "IPv6 link-local" => "https://[fe80::1]/v1",
      "AWS metadata" => "https://169.254.169.254/v1"
    }.each do |label, url|
      it "rejects #{label} as a prohibited destination" do
        expect { described_class.validate_url!(url) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("endpoint_forbidden")
          expect(error.message).not_to include(URI.parse(url).host)
        }
      end
    end

    it "allows the trusted native Bonsai 8080 endpoint in production" do
      connection = Llm::ProviderConnection.new(provider: "bonsai", model: "bonsai-2-27b")

      expect(connection.endpoint_for("chat/completions")).to eq("http://127.0.0.1:8080/v1/chat/completions")
    end

    it "allows the trusted native Bonsai 8910 endpoint in production" do
      connection = Llm::ProviderConnection.new(provider: "bonsai", model: "bonsai-27b")

      expect(connection.endpoint_for("chat/completions")).to eq("http://127.0.0.1:8910/v1/chat/completions")
    end

    it "allows the Docker host gateway only for a trusted local provider" do
      allow(Resolv).to receive(:getaddresses).with("host.docker.internal").and_return([ "172.17.0.1" ])
      connection = Llm::ProviderConnection.new(provider: "bonsai", model: "bonsai-2-27b",
        base_url: "http://host.docker.internal:8080/v1")

      expect(connection.endpoint_for("chat/completions"))
        .to eq("http://host.docker.internal:8080/v1/chat/completions")
      expect(connection.pinned_address_for("http://host.docker.internal:8080/v1/chat/completions")).to eq("172.17.0.1")
    end

    it "rejects a private endpoint even when the provider is normally local" do
      connection = Llm::ProviderConnection.new(provider: "bonsai", model: "bonsai-2-27b",
        base_url: "http://192.168.1.10:8080/v1")

      expect { connection.endpoint_for("chat/completions") }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("endpoint_forbidden")
      }
    end

    it "does not let trusted_local relax a remote endpoint policy" do
      expect { described_class.validate_url!("http://127.0.0.1:8080/v1", trusted_local: true) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
      expect { described_class.validate_url!("http://host.docker.internal:8080/v1", trusted_local: true) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
    end

    {
      "Alibaba metadata" => "https://100.100.100.200/v1",
      "unspecified IPv4" => "https://0.0.0.0/v1",
      "unspecified IPv6" => "https://[::]/v1",
      "IPv4 multicast" => "https://224.0.0.1/v1",
      "IPv6 multicast" => "https://[ff02::1]/v1",
      "documentation-reserved IPv4" => "https://192.0.2.1/v1",
      "class-E reserved IPv4" => "https://240.0.0.1/v1",
      "documentation-reserved IPv6" => "https://[2001:db8::1]/v1"
    }.each do |label, url|
      it "rejects #{label} in special-use networks" do
        expect { described_class.validate_url!(url) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("endpoint_forbidden")
        }
      end
    end

    it "rejects a hostname with any prohibited resolved address" do
      allow(Resolv).to receive(:getaddresses).with("mixed.example.test").and_return([ "93.184.216.34", "10.0.0.1" ])

      expect { described_class.validate_url!("https://mixed.example.test/v1") }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
    end
  end

  context "with development endpoint policy" do
    before { allow(Rails.env).to receive(:production?).and_return(false) }

    it "preserves the explicitly trusted host-local Bonsai endpoint" do
      connection = Llm::ProviderConnection.new(provider: "bonsai", model: "bonsai-2-27b")

      expect(connection.endpoint_for("chat/completions")).to eq("http://127.0.0.1:8080/v1/chat/completions")
    end

    it "continues to reject private destinations" do
      expect { described_class.validate_url!("https://192.168.1.10/v1") }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
    end

    it "rejects an untrusted loopback custom endpoint with a typed error" do
      expect { described_class.validate_url!("http://127.0.0.1:8080/v1") }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("endpoint_forbidden") }
    end

    it "allows a public HTTPS destination" do
      expect(described_class.validate_url!("https://93.184.216.34/v1/")).to eq("https://93.184.216.34/v1")
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
