# frozen_string_literal: true

# Phase 3e — Images::Generator against a webmock-stubbed OpenAI Images API.
# Proves the provider contract the rest of the app relies on: gpt-image-1
# never sends response_format, the dall-e-3 fallback does, readable
# user-facing errors replace raw provider bodies, and transport timeouts are
# retried exactly once then surfaced honestly.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub

require "rails_helper"

RSpec.describe Images::Generator do
  subject(:generator) { described_class.new(api_key: api_key) }

  let(:api_key) { "sk-test-image" }
  let(:url) { "https://api.openai.com/v1/images/generations" }
  let(:b64) { "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" }
  let(:success_body) do
    {
      created: 1_730_000_000,
      data: [ { b64_json: b64, revised_prompt: "A calm alpine lake at sunrise in oil paint", id: "img_123" } ]
    }
  end
  let(:json_ok) { { status: 200, body: success_body.to_json, headers: { "Content-Type" => "application/json" } } }


  def stub_generation(matcher = nil)
    stub_request(:post, url).with(matcher).to_return(json_ok)
  end

  describe "configuration" do
    it "is not configured without a key and says so readably" do
      expect { described_class.new(api_key: "").generate(prompt: "anything") }
        .to raise_error(described_class::NotConfigured, /not configured/i)
    end

    it "needs a prompt" do
      expect { generator.generate(prompt: "  ") }
        .to raise_error(described_class::Error, /needs a prompt/i)
    end

    it "loads the key through the shared credentials-then-ENV idiom" do
      allow(Rails.application.credentials).to receive(:dig).with(:openai, :api_key).and_return(nil)
      original = ENV["OPENAI_API_KEY"]
      ENV["OPENAI_API_KEY"] = "sk-from-env"
      expect(described_class.new.api_key).to eq("sk-from-env")
      expect(described_class.configured?).to be(true)
    ensure
      ENV["OPENAI_API_KEY"] = original
    end
  end

  describe "gpt-image-1 request contract" do
    it "POSTs model/prompt/size/quality/n with the bearer key and NEVER response_format" do
      stub = stub_generation(
        headers: { "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json" },
        body: hash_including("model" => "gpt-image-1", "prompt" => "a lake",
                             "size" => "1024x1536", "quality" => "high", "n" => 1)
      )
      # A second, independent guard: the outgoing body must not carry the key.
      allow_json = stub_generation(
        body: ->(raw) { JSON.parse(raw).key?("response_format") }
      )

      result = generator.generate(prompt: "a lake", size: "1024x1536", quality: "high", n: 1)

      expect(stub).to have_been_requested.once
      expect(allow_json).not_to have_been_requested

      expect(result.images.size).to eq(1)
      expect(result.images.first.b64_json).to eq(b64)
      expect(result.images.first.revised_prompt).to include("alpine lake")
      expect(result.images.first.provider_id).to eq("img_123")
      expect(result.created).to eq(1_730_000_000)
      expect(result.model).to eq("gpt-image-1")
    end

    it "defaults blank quality to auto" do
      stub = stub_generation(body: hash_including("quality" => "auto"))
      generator.generate(prompt: "a lake", quality: nil)
      expect(stub).to have_been_requested
    end
  end

  describe "dall-e-3 fallback contract" do
    let(:generator) { described_class.new(api_key: api_key, model: "dall-e-3") }

    it "sends response_format=b64_json and maps quality/size/n to dall-e vocabulary" do
      stub = stub_generation(
        body: hash_including("response_format" => "b64_json", "quality" => "standard",
                             "size" => "1024x1792", "n" => 1)
      )

      generator.generate(prompt: "a lake", size: "1024x1536", quality: "auto", n: 2)

      expect(stub).to have_been_requested
    end
  end

  describe "provider failures" do
    it "surfaces rejection reasons as readable user-facing errors" do
      stub_request(:post, url).to_return(
        status: 400,
        body: { error: { message: "Your prompt was flagged by our moderation systems." } }.to_json
      )

      expect { generator.generate(prompt: "naughty thing") }
        .to raise_error(described_class::Error, /flagged by our moderation systems/)
    end

    it "translates auth failures into key guidance, not raw bodies" do
      stub_request(:post, url).to_return(status: 401, body: { error: { message: "Invalid API key" } }.to_json)
      expect { generator.generate(prompt: "a lake") }
        .to raise_error(described_class::Error, /API key was rejected/)
    end

    it "raises when the response carries no images" do
      stub_request(:post, url).to_return(status: 200, body: { created: 1, data: [] }.to_json)
      expect { generator.generate(prompt: "a lake") }
        .to raise_error(described_class::Error, /no images/)
    end

    it "raises on unreadable bodies instead of crashing" do
      stub_request(:post, url).to_return(status: 200, body: "not-json")
      expect { generator.generate(prompt: "a lake") }
        .to raise_error(described_class::Error, /unreadable|no images/i)
    end
  end

  describe "timeout path" do
    it "retries transport timeouts then reports a readable timeout error" do
      stub_request(:post, url).to_timeout
      allow(generator).to receive(:sleep)

      expect { generator.generate(prompt: "a lake") }
        .to raise_error(described_class::Error, /timed out/i)

      expect(a_request(:post, url)).to have_been_requested.times(described_class::MAX_ATTEMPTS)
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
