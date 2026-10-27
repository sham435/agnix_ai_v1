# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

# Routing is driven by the PROVIDER, never by a stored model label. These
# specs lock the fix for "claude-sonnet-4-6 shows online but not responding":
# a bonsai-provider conversation carrying a stale/foreign label must reach the
# live Bonsai 2 server (:8080), never the dead 1-bit port (:8910).
RSpec.describe Llm::Client do
  around do |example|
    original = ENV.to_hash
    ENV["BONSAI_BASE_URL"] = "http://127.0.0.1:8910/v1"
    ENV["BONSAI2_BASE_URL"] = "http://127.0.0.1:8080/v1"
    ENV["BONSAI_MODEL"] = "bonsai-2-27b"
    example.run
  ensure
    ENV.replace(original)
  end

  def bonsai_client(model:, api_key: "local", **opts)
    described_class.new(provider: "bonsai", model: model, api_key: api_key, **opts)
  end

  def built_with(&block)
    captured = nil
    allow(Llm::OpenaiAdapter).to receive(:new) do |**kwargs|
      captured = kwargs
      instance_double(Llm::OpenaiAdapter, chat: { content: "", tool_calls: [], tokens: 0 })
    end
    block.call
    captured
  end

  it "routes a stale foreign model label to the Bonsai 2 endpoint (:8080) and normalizes the model id" do
    kwargs = built_with do
      bonsai_client(model: "claude-sonnet-4-6").chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:base_url]).to eq("http://127.0.0.1:8080/v1")
    expect(kwargs[:model]).to eq("bonsai-2-27b")
  end

  it "never sends default bonsai traffic to the 1-bit :8910 port" do
    kwargs = built_with do
      bonsai_client(model: "claude-sonnet-4-6").chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:base_url]).not_to include("8910")
  end

  it "routes the explicit 1-bit model to the legacy BONSAI_BASE_URL endpoint" do
    kwargs = built_with do
      bonsai_client(model: "bonsai-27b").chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:base_url]).to eq("http://127.0.0.1:8910/v1")
    # The explicit 1-bit id is preserved, never normalized away.
    expect(kwargs[:model]).to eq("bonsai-27b")
  end

  it "honours an explicit BONSAI2_BASE_URL override for the primary endpoint" do
    ENV["BONSAI2_BASE_URL"] = "http://127.0.0.1:9099/v1"

    kwargs = built_with do
      bonsai_client(model: "bonsai-2-27b").chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:base_url]).to eq("http://127.0.0.1:9099/v1")
  end

  it "honours an explicit BONSAI_MODEL override when normalizing" do
    ENV["BONSAI_MODEL"] = "custom-bonsai-alias"

    kwargs = built_with do
      bonsai_client(model: "gpt-9000").chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:model]).to eq("custom-bonsai-alias")
    expect(kwargs[:base_url]).to eq("http://127.0.0.1:8080/v1")
  end

  it "does not touch bonsai routing for other providers" do
    kwargs = built_with do
      described_class.new(provider: "openai", model: "gpt-4o", api_key: "sk-x")
        .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs[:model]).to eq("gpt-4o")
    expect(kwargs[:base_url]).to be_nil
  end

  # Google used to be enum-only: Agent::MODELS had no :google key, so
  # Llm::Client raised "Unknown LLM provider: google" for any google agent.
  # It now rides the shared OpenAI-compatible adapter against Gemini's
  # compatibility endpoint.
  describe "google" do
    def google_client(model:, api_key: "AIza-test-key")
      described_class.new(provider: "google", model: model, api_key: api_key)
    end

    it "builds the OpenAI-compatible adapter against the Gemini endpoint and keeps the model id" do
      kwargs = built_with do
        google_client(model: "gemini-2.5-flash")
          .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://generativelanguage.googleapis.com/v1beta/openai/v1")
      expect(kwargs[:model]).to eq("gemini-2.5-flash")
      expect(kwargs[:api_key]).to eq("AIza-test-key")
    end

    it "honours an explicit GOOGLE_BASE_URL override" do
      ENV["GOOGLE_BASE_URL"] = "https://proxy.example.test/v1beta/openai/v1"

      kwargs = built_with do
        google_client(model: "gemini-3.5-flash")
          .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://proxy.example.test/v1beta/openai/v1")
    end

    it "never falls through to another provider when the key is missing" do
      kwargs = built_with do
        google_client(model: "gemini-2.5-flash", api_key: nil)
          .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://generativelanguage.googleapis.com/v1beta/openai/v1")
      expect(kwargs[:api_key]).to be_nil
    end
  end
end
