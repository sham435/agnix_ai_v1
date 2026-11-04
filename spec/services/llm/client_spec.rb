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
    ENV["OPENROUTER_BASE_URL"] = "https://openrouter.ai/api/v1"
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

  # The template inside the Bonsai GGUF thinks unless told not to
  # (`enable_thinking` undefined counts as true, `reasoning_effort` defaults to
  # xhigh). Live measurement on a five-file request: 8192/8192 tokens streamed
  # as reasoning_content, none as content, finish_reason "length" - an empty
  # reply stored as a succeeded run. With thinking off the same request
  # finished at 3112 tokens with 10,377 characters of answer.
  it "builds every bonsai adapter with the chain of thought switched off" do
    [ "bonsai-2-27b", "bonsai-27b", "claude-sonnet-4-6" ].each do |label|
      kwargs = built_with do
        bonsai_client(model: label).chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:chat_template_kwargs]).to eq({ "enable_thinking" => false })
    end
  end

  it "sends no chat template kwargs to routes that did not ask for one" do
    kwargs = built_with do
      described_class.new(provider: "openai", model: "gpt-4o", api_key: "sk-x")
        .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
    end

    expect(kwargs).not_to have_key(:chat_template_kwargs)
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

  # openrouter is a provider in its own right now (Flint is its verified
  # route), so reaching the gateway no longer depends on an "openai" agent
  # happening to hold a key that starts with sk-or-v1.
  describe "openrouter" do
    def openrouter_client(model: "recursive/flint-v1.0:free", api_key: "sk-or-v1-test-key")
      described_class.new(provider: "openrouter", model: model, api_key: api_key)
    end

    it "builds the OpenAI-compatible adapter against the gateway and keeps the route id" do
      kwargs = built_with do
        openrouter_client.chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://openrouter.ai/api/v1")
      # Namespace colon and ":free" tier suffix are part of OpenRouter's id.
      expect(kwargs[:model]).to eq("recursive/flint-v1.0:free")
      expect(kwargs[:api_key]).to eq("sk-or-v1-test-key")
    end

    it "routes by the chosen provider even when the key has no OpenRouter prefix" do
      kwargs = built_with do
        openrouter_client(api_key: "an-org-key-without-the-old-prefix")
          .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://openrouter.ai/api/v1")
    end

    it "honours an explicit OPENROUTER_BASE_URL override" do
      ENV["OPENROUTER_BASE_URL"] = "https://proxy.example.test/api/v1"

      kwargs = built_with do
        openrouter_client.chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://proxy.example.test/api/v1")
    end

    it "falls back to the public gateway when OPENROUTER_BASE_URL is unset" do
      ENV.delete("OPENROUTER_BASE_URL")

      kwargs = built_with do
        openrouter_client.chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://openrouter.ai/api/v1")
    end

    it "never sends openrouter traffic to the raw OpenAI host" do
      kwargs = built_with do
        openrouter_client.chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).not_to include("api.openai.com")
    end

    # Rows saved before the provider existed stay reachable: an "openai" agent
    # wearing an OpenRouter key must not start 401ing against api.openai.com.
    it "keeps the legacy sk-or-v1 sniff on the openai branch pointed at the same gateway" do
      kwargs = built_with do
        described_class.new(provider: "openai", model: "recursive/flint-v1.0:free", api_key: "sk-or-v1-legacy")
          .chat(messages: [ { role: "user", content: "hi" } ], tools: [])
      end

      expect(kwargs[:base_url]).to eq("https://openrouter.ai/api/v1")
      expect(kwargs[:model]).to eq("recursive/flint-v1.0:free")
    end
  end

  # §2: per-turn generation budgets. The client forwards a per-call
  # max_tokens override to the adapter when a caller asks for a smaller window
  # (plan turns, intermediate tool-selection turns), and otherwise sends the
  # configured cap so the final answer keeps the full budget.
  describe "per-call max_tokens override" do
    def recording_adapter
      adapter = Object.new
      def adapter.chat(messages:, tools:, temperature:, max_tokens:, top_p:, stream:); { max_tokens: max_tokens }; end
      def adapter.stream_chat(messages:, tools:, temperature:, max_tokens:, top_p:); { max_tokens: max_tokens }; end
      allow(Llm::OpenaiAdapter).to receive(:new).and_return(adapter)
      adapter
    end

    it "uses the override when one is given" do
      recording_adapter
      client = described_class.new(provider: "openai", model: "gpt-4o", api_key: "sk-x", max_tokens: 8192)

      expect(client.chat(messages: [], tools: [], max_tokens: 1024)[:max_tokens]).to eq(1024)
      expect(client.stream_chat(messages: [], tools: [], max_tokens: 2048)[:max_tokens]).to eq(2048)
    end

    it "falls back to the configured cap when no override is given" do
      recording_adapter
      client = described_class.new(provider: "openai", model: "gpt-4o", api_key: "sk-x", max_tokens: 8192)

      expect(client.chat(messages: [], tools: [])[:max_tokens]).to eq(8192)
      expect(client.stream_chat(messages: [], tools: [])[:max_tokens]).to eq(8192)
    end
  end
end
