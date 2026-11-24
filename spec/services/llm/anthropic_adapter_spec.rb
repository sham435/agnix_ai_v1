# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Llm::AnthropicAdapter do
  let(:adapter) { described_class.new(api_key: "test-key", model: "claude-sonnet-4-6") }

  around do |example|
    original_env = ENV.to_hash
    ENV.delete("ANTHROPIC_BASE_URL")
    example.run
  ensure
    ENV.replace(original_env)
  end

  # The adapter now replays transient failures with a backoff; keep that out of
  # the spec's real clock so retry cases stay fast and deterministic.
  before { allow(adapter).to receive(:sleep) }

  # Mimic HTTParty's stream_body block: hand the whole response body to the
  # adapter in one chunk.
  def stub_body(body)
    allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
      blk&.call(body)
    end
  end

  # HTTParty streams the body through HTTParty::ResponseFragment, which delegates
  # the raw chunk text and also answers #code with the status line. A double with
  # those two messages drives the adapter exactly as a live API does; stub_body
  # above hands over bare Strings, which carry no status at all.
  def stream_fragment(text, code)
    double(to_s: text, code: code)
  end

  def stub_stream_fragments(fragments, returns: nil)
    allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
      fragments.each { |fragment| blk&.call(fragment) }
      returns
    end
  end

  def capture_anthropic_logs
    messages = []
    allow(Rails.logger).to receive(:error) { |message| messages << message.to_s }
    allow(Rails.logger).to receive(:warn) { |message| messages << message.to_s }
    messages
  end

  describe "#stream_chat" do
    it "streams genuine text deltas from a real SSE response" do
      sse = [
        { type: "content_block_delta", delta: { type: "text_delta", text: "Hi " } }.to_json,
        { type: "content_block_delta", delta: { type: "text_delta", text: "there" } }.to_json
      ].map { |e| "data: #{e}\n\n" }.join
      stub_body(sse)

      pieces = []
      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 20) { |t, _f, _tc| pieces << t }

      expect(result[:content]).to eq("Hi there")
      expect(pieces).to eq([ "Hi ", "there" ])
    end

    it "falls back to a buffered (non-SSE) JSON body instead of returning empty" do
      # Regression guard: streaming turns for tool-bearing agents must still
      # render when a gateway ignores stream:true and replies with one complete
      # JSON message (the shape the older non-streaming stubs used).
      buffered = {
        content: [ { type: "text", text: "Hello there!" } ],
        usage: { output_tokens: 5 }
      }.to_json
      stub_body(buffered)

      pieces = []
      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 20) { |t, _f, _tc| pieces << t }

      expect(result[:content]).to eq("Hello there!")
      expect(result[:content]).not_to be_blank
      expect(pieces).to eq([ "Hello there!" ])
    end

    it "parses tool_use blocks from a buffered body" do
      buffered = {
        content: [ { type: "tool_use", id: "t1", name: "calculator", input: { expression: "2+2" } } ]
      }.to_json
      stub_body(buffered)

      result = adapter.stream_chat(messages: [ { role: "user", content: "compute" } ], tools: [],
                                   temperature: 0.7, max_tokens: 20) { |_t, _f, _tc| }

      expect(result[:tool_calls]).to be_present
      expect(result[:tool_calls].first[:function][:name]).to eq("calculator")
    end

    it "classifies a JSON error without exposing the raw provider message" do
      raw_message = "Your credit balance is too low to access the Anthropic API."
      stub_body({ type: "error",
                  error: { type: "invalid_request_error", message: raw_message } }.to_json)

      expect {
        adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                            temperature: 0.7, max_tokens: 20) { |_t, _f, _tc| }
      }.to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
        expect(error).to be_a(Llm::ProviderError)
        expect(error.code).to eq(:provider_credit_insufficient)
        expect(error.retryable?).to be(false)
        expect(error.message).to include("insufficient credits or quota")
        expect(error.message).not_to include(raw_message, "test-key")
      }
    end
  end

  # The shape check above only catches a rejection that arrives as Anthropic's
  # own error JSON. Anything else - a proxy's HTML 502, a bodyless 429 - was
  # dropped by the SSE parser and finalized as an empty turn, so the status line
  # is now read off the stream itself.
  describe "HTTP status failures" do
    def stream(&block)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &block)
    end

    it "reports a safe typed status without exposing or logging the provider body" do
      raw_body = %({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}})
      logs = capture_anthropic_logs
      stub_stream_fragments([ stream_fragment(raw_body, 529) ], returns: double(code: "529"))

      pieces = []
      expect { stream { |text, *_| pieces << text } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error.code).to eq(:provider_overloaded)
          expect(error.status).to eq(529)
          expect(error.provider_error_type).to eq("overloaded_error")
          expect(error.retryable?).to be(true)
          expect(error.message).to include("HTTP 529", "temporarily unavailable")
          expect(error.message).not_to include("overloaded_error", "Overloaded")
        }
      expect(pieces).to be_empty
      expect(logs.join).not_to include(raw_body, "Overloaded", "test-key")
    end

    it "treats a non-2xx HTML body as a failure, not as a buffered message" do
      # Previously this reached the buffered-response fallback as unparseable
      # text and finalized the turn with content "", blaming the model for a
      # gateway that never reached it.
      page = "<html>\n<head><title>502 Bad Gateway</title></head>\n<body>upstream gone</body>\n</html>"
      logs = capture_anthropic_logs
      stub_stream_fragments([ stream_fragment(page, 502) ])

      pieces = []
      expect { stream { |text, *_| pieces << text } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error.code).to eq(:provider_unavailable)
          expect(error.status).to eq(502)
          expect(error.retryable?).to be(true)
          expect(error.message).to include("HTTP 502")
          expect(error.message).not_to include("502 Bad Gateway", "upstream gone", "\n")
        }
      expect(pieces).to be_empty
      expect(logs.join).not_to include(page, "upstream gone")
    end

    it "names the status and safe classification when the error response has no body" do
      stub_stream_fragments([ stream_fragment("", 429) ])

      expect { stream }.to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
        expect(error.code).to eq(:provider_rate_limited)
        expect(error.status).to eq(429)
        expect(error.message).to include("HTTP 429", "rate limit was reached")
      }
    end

    it "reads the status from the completed response when no fragment is streamed" do
      allow(HTTParty).to receive(:post).and_return(double(code: "401"))

      expect { stream }.to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
        expect(error.code).to eq(:provider_authentication_failed)
        expect(error.status).to eq(401)
        expect(error.message).to include("HTTP 401", "rejected the configured credentials")
      }
    end

    it "streams text deltas while the transport reports 200" do
      first = { type: "content_block_delta", delta: { type: "text_delta", text: "Hi " } }.to_json
      second = { type: "content_block_delta", delta: { type: "text_delta", text: "there" } }.to_json
      stub_stream_fragments([
        stream_fragment("data: #{first}\n\n", 200),
        stream_fragment("data: #{second}\n\n", 200)
      ], returns: double(code: "200"))

      pieces = []
      result = stream { |text, *_| pieces << text }

      expect(result[:content]).to eq("Hi there")
      expect(pieces).to eq([ "Hi ", "there" ])
    end

    it "still accepts a buffered 200 body from a gateway that ignored stream:true" do
      buffered = { content: [ { type: "text", text: "Hello there!" } ] }.to_json
      stub_stream_fragments([ stream_fragment(buffered, 200) ], returns: double(code: "200"))

      pieces = []
      result = stream { |text, *_| pieces << text }

      expect(result[:content]).to eq("Hello there!")
      expect(pieces).to eq([ "Hello there!" ])
    end
  end

  describe "secure transport" do
    let(:key) { "test-key" }
    let(:model) { "claude-sonnet-4-6" }
    let(:config) { {} }
    let(:integration) do
      instance_double(ToolIntegration, config: config, api_key: key, decrypted_credentials: { "api_key" => key })
    end

    it "uses the shared endpoint, native authentication, bounded timeouts, and proxy bypass" do
      captured = nil
      response = double(code: 200, success?: true, headers: {}, body: { content: [] }.to_json)
      allow(HTTParty).to receive(:post) do |url, options|
        captured = [ url, options ]
        response
      end

      adapter.sync_chat(messages: [ { role: "user", content: "hi" } ], tools: [], temperature: 0.7, max_tokens: 20)

      expect(captured.first).to eq("https://api.anthropic.com/v1/messages")
      expect(captured.last).to include(timeout: 120, open_timeout: 10, follow_redirects: false,
        http_proxyaddr: nil, stream_body: false)
      expect(captured.last[:headers]).to include("X-Api-Key" => key,
        "anthropic-version" => ENV.fetch("ANTHROPIC_API_VERSION", "2023-06-01"), "Content-Type" => "application/json")
      expect(captured.last[:headers]).not_to have_key("Authorization")
    end

    it "pins a custom endpoint and applies its configured transport limits" do
      config.merge!("open_timeout" => 3, "read_timeout" => 19)
      connection = Llm::ProviderConnection.new(provider: "anthropic", integration: integration, model: model,
        base_url: "https://anthropic-proxy.example.test/v1")
      custom_adapter = described_class.new(api_key: key, model: model, connection: connection)
      allow(Llm::ProviderEndpoint).to receive(:enforce_destination!).and_return("93.184.216.34")
      captured = nil
      allow(HTTParty).to receive(:post) do |url, options|
        adapter_options = options.fetch(:connection_adapter)
        captured_ip = adapter_options.call(URI.parse(url), options).ipaddr
        captured = [ url, options, captured_ip ]
        double(code: 200, success?: true, headers: {}, body: { content: [] }.to_json)
      end

      custom_adapter.sync_chat(messages: [], tools: [], temperature: 0.7, max_tokens: 20)

      expect(captured.first).to eq("https://anthropic-proxy.example.test/v1/messages")
      expect(captured[1]).to include(timeout: 19, open_timeout: 3)
      expect(captured.last).to eq("93.184.216.34")
    end

    it "converts an oversized response to a non-retryable typed error" do
      config["max_response_bytes"] = 1024
      connection = Llm::ProviderConnection.new(provider: "anthropic", integration: integration, model: model)
      custom_adapter = described_class.new(api_key: key, model: model, connection: connection)
      allow(HTTParty).to receive(:post).and_return(
        double(code: 200, success?: true, headers: {}, body: "x" * 2048)
      )

      expect { custom_adapter.sync_chat(messages: [], tools: [], temperature: 0.7, max_tokens: 20) }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error).to be_a(Llm::ProviderError)
          expect(error.code).to eq(:response_too_large)
          expect(error.retryable?).to be(false)
          expect(error.message).to include("size limit")
        }
      expect(HTTParty).to have_received(:post).once
    end

    it "aborts an oversized stream with a typed error" do
      config["max_stream_bytes"] = 1024
      connection = Llm::ProviderConnection.new(provider: "anthropic", integration: integration, model: model)
      custom_adapter = described_class.new(api_key: key, model: model, connection: connection)
      allow(HTTParty).to receive(:post) do |_url, _options, &block|
        block.call("x" * 600)
        block.call("x" * 600)
        double(code: 200, headers: {}, body: "")
      end

      expect { custom_adapter.stream_chat(messages: [], tools: [], temperature: 0.7, max_tokens: 20) }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error.code).to eq(:response_too_large)
          expect(error.retryable?).to be(false)
        }
      expect(HTTParty).to have_received(:post).once
    end
  end

  # The provider's failure is now a typed error, not just prose: `code` names the
  # cause and `retryable` says whether redelivery can help. Classification must
  # catch the credit case even when Anthropic files it as a generic 400, because
  # that is exactly how an out-of-credit key surfaces.
  describe "typed provider errors" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "files a spending ceiling that arrives as a 400 invalid_request_error as credit without leaking its message" do
      raw_message = "Your credit balance is too low to access the Anthropic API."
      stub_body({ type: "error",
                  error: { type: "invalid_request_error", message: raw_message } }.to_json)

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) do |e|
        expect(e.code).to eq(:provider_credit_insufficient)
        expect(e.retryable?).to be(false)
        expect(e.message).to include("insufficient credits or quota")
        expect(e.message).not_to include(raw_message)
      end
    end

    it "labels a bad key as authentication failure and does not retry it" do
      stub_stream_fragments([ stream_fragment("", 401) ])

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_authentication_failed)
          expect(e.retryable?).to be(false)
        }
      expect(HTTParty).to have_received(:post).once
    end

    it "marks throttling retryable and burns the full retry budget first" do
      stub_stream_fragments(
        [ stream_fragment(%({"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}), 429) ],
        returns: double(code: "429", headers: {})
      )

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_rate_limited)
          expect(e.retryable?).to be(true)
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_RETRIES).times
    end

    it "labels a capacity overload retryable" do
      stub_stream_fragments([
        stream_fragment(%({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}), 529)
      ])

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_overloaded)
          expect(e.retryable?).to be(true)
        }
    end

    it "prefers the provider's structured error.type over the raw status bucket" do
      stub_stream_fragments([
        stream_fragment(%({"type":"error","error":{"type":"permission_error","message":"Not allowed to use this model."}}), 403)
      ])

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_permission_denied)
          expect(e.retryable?).to be(false)
          expect(e.status).to eq(403)
        }
    end
  end

  describe "sync_chat typed errors" do
    def sync!
      adapter.sync_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                        temperature: 0.7, max_tokens: 20)
    end

    it "types a retryable server fault" do
      response = double(code: 500, success?: false, headers: {},
                        body: %({"type":"error","error":{"type":"api_error","message":"Internal"}}))
      allow(HTTParty).to receive(:post).and_return(response)

      expect { sync! }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(true)
          expect(e.message).to include("HTTP 500", "temporarily unavailable")
          expect(e.message).not_to include("Internal")
        }
    end

    it "does not retry a permanent rejection" do
      response = double(code: 400, success?: false, headers: {},
                        body: %({"type":"error","error":{"type":"invalid_request_error","message":"Bad params"}}))
      allow(HTTParty).to receive(:post).and_return(response)

      expect { sync! }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_request_rejected)
          expect(e.retryable?).to be(false)
          expect(e.message).to include("HTTP 400")
          expect(e.message).not_to include("Bad params")
        }
      expect(HTTParty).to have_received(:post).once
    end

    it "redacts a malformed successful response instead of exposing parser details" do
      raw_marker = "RAW-MALFORMED-ANTHROPIC-BODY"
      response = double(code: 200, success?: true, headers: {}, body: %({"content":"#{raw_marker}"))
      allow(HTTParty).to receive(:post).and_return(response)

      expect { sync! }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:invalid_provider_response)
          expect(e.retryable?).to be(false)
          expect(e.message).to include("invalid response")
          expect(e.message).not_to include(raw_marker)
        }
      expect(HTTParty).to have_received(:post).once
    end
  end

  describe "retry behaviour" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "replays a transient failure and succeeds when the next attempt streams" do
      calls = 0
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        calls += 1
        if calls == 1
          blk&.call(stream_fragment("", 529))
          double(code: "529")
        else
          ok = { type: "content_block_delta", delta: { type: "text_delta", text: "recovered" } }.to_json
          blk&.call(stream_fragment("data: #{ok}\n\n", 200))
          double(code: "200")
        end
      end

      pieces = []
      result = stream { |text, *_| pieces << text }

      expect(calls).to eq(2)
      expect(result[:content]).to eq("recovered")
      expect(pieces).to eq([ "recovered" ])
    end

    it "classifies a refused connection as unreachable and fails fast (one quick replay only)" do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unreachable)
          expect(e.retryable?).to be(true)
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_CONNECT_RETRIES + 1).times
    end

    it "classifies a read timeout as a timeout" do
      allow(HTTParty).to receive(:post).and_raise(Net::ReadTimeout)

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_timeout)
        }
    end

    it "never replays an attempt that already streamed content (no user-visible duplication)" do
      calls = 0
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        calls += 1
        chunk = { type: "content_block_delta", delta: { type: "text_delta", text: "Hi " } }.to_json
        blk&.call(stream_fragment("data: #{chunk}\n\n", 200))
        raise EOFError
      end

      expect { stream { |_t, *_| } }.to raise_error(Llm::AnthropicAdapter::LlmError)
      expect(calls).to eq(1)
    end

    it "does not mark a transport failure that already streamed as replayable (§A honesty)" do
      # The replay was skipped because text reached the user, so claiming the
      # error is retryable would invite a higher layer to re-run it and duplicate
      # the reply. The flag must be false once content has streamed.
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        chunk = { type: "content_block_delta", delta: { type: "text_delta", text: "Hi " } }.to_json
        blk&.call(stream_fragment("data: #{chunk}\n\n", 200))
        raise EOFError
      end

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(false)
        }
      expect(HTTParty).to have_received(:post).once
    end

    it "downgrades a retryable HTTP error that arrived mid-stream after content streamed" do
      # A gateway that streams a 200 delta and THEN flips to a 500 would otherwise
      # surface a retryable error, even though the turn is unreplayable.
      delta = { type: "content_block_delta", delta: { type: "text_delta", text: "Hello " } }.to_json
      stub_stream_fragments([
        stream_fragment("data: #{delta}\n\n", 200),
        stream_fragment(%({"type":"error","error":{"type":"api_error","message":"boom"}}), 500)
      ], returns: double(code: "500"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(false)
        }
      expect(HTTParty).to have_received(:post).once
    end
  end

  # The provider's Retry-After is a suggestion we should obey, capped at our own
  # ceiling - not silently dropped, which would turn a polite 60s wait into three
  # retries inside ~6s and deepen the throttle.
  describe "Retry-After handling" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "caps a hint above the ceiling rather than reverting to fast retries" do
      stub_stream_fragments(
        [ stream_fragment(%({"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}), 429) ],
        returns: double(code: "429", headers: { "retry-after" => "60" })
      )

      expect { stream { |_t, *_| } }.to raise_error(Llm::AnthropicAdapter::LlmError)
      expect(adapter).to have_received(:sleep)
        .with(described_class::RETRY_AFTER_MAX).twice
    end

    it "sleeps a hint under the ceiling verbatim" do
      stub_stream_fragments(
        [ stream_fragment(%({"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}), 429) ],
        returns: double(code: "429", headers: { "retry-after" => "5" })
      )

      expect { stream { |_t, *_| } }.to raise_error(Llm::AnthropicAdapter::LlmError)
      expect(adapter).to have_received(:sleep).with(5).twice
    end
  end

  # Classification sees only a bounded error prefix. A credit marker inside that
  # prefix must still win over the generic 400 classification.
  describe "classification robustness" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "sniffs the credit cause from the bounded prefix of a large error body" do
      filler = "detail " * 300
      body = { type: "error",
               error: { type: "invalid_request_error",
                        message: "Your credit balance is too low to access the Anthropic API. #{filler}" } }.to_json
      expect(body.bytesize).to be > described_class::ERROR_CLASSIFY_LIMIT

      stub_stream_fragments([ stream_fragment(body, 400) ], returns: double(code: "400"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_credit_insufficient)
          expect(e.retryable?).to be(false)
        }
    end
  end

  # These examples close the retry/error-handling branches that had no coverage:
  # the whole sync_chat transport path, the coarse status-class fallbacks in
  # classify, and the defensive edges around Retry-After, status parsing, and
  # malformed SSE. Each asserts real behavior (classification, retry budget, or
  # the absence of a retry), not just that a line executed.
  describe "retry & error-path branch coverage" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    def sync!
      adapter.sync_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                        temperature: 0.7, max_tokens: 20)
    end

    it "routes #chat to the streaming path and forwards deltas to the block" do
      delta = { type: "content_block_delta", delta: { type: "text_delta", text: "hi" } }.to_json
      stub_body("data: #{delta}\n\n")

      pieces = []
      result = adapter.chat(messages: [ { role: "user", content: "q" } ], tools: [],
                            temperature: 0.7, max_tokens: 10, stream: true) { |t, *_| pieces << t }

      expect(result[:content]).to eq("hi")
      expect(result[:finish_reason]).to eq("stop")
      expect(pieces).to eq([ "hi" ])
    end

    it "routes #chat to the sync path" do
      allow(HTTParty).to receive(:post).and_return(
        double(code: 200, success?: true, body: { content: [ { type: "text", text: "pong" } ] }.to_json)
      )

      result = adapter.chat(messages: [ { role: "user", content: "q" } ], tools: [],
                            temperature: 0.7, max_tokens: 10, stream: false)

      expect(result[:content]).to eq("pong")
    end

    it "replays a sync transport blip through the full budget, then fails as transient" do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNRESET)

      expect { sync! }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(true)
          expect(e.message).to include("Errno::ECONNRESET")
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_RETRIES).times
    end

    it "fast-fails a sync connection refusal after one quick replay" do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)

      expect { sync! }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unreachable)
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_CONNECT_RETRIES + 1).times
    end

    it "classifies an unmapped 5xx as a retryable server fault" do
      stub_stream_fragments([ stream_fragment("server exploded", 599) ], returns: double(code: "599"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(true)
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_RETRIES).times
    end

    it "classifies an unmapped 4xx as a permanent rejection and never retries" do
      stub_stream_fragments([ stream_fragment("unavailable for legal reasons", 451) ], returns: double(code: "451"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_request_rejected)
          expect(e.retryable?).to be(false)
        }
      expect(HTTParty).to have_received(:post).once
    end

    it "falls through to a transient default for an unknown provider error type" do
      stub_body({ type: "error", error: { type: "mystery_error", message: "unrecognized" } }.to_json)

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_unavailable)
          expect(e.retryable?).to be(true)
        }
      expect(HTTParty).to have_received(:post).exactly(described_class::MAX_RETRIES).times
    end

    it "ignores a non-numeric Retry-After and backs off linearly" do
      stub_stream_fragments(
        [ stream_fragment(%({"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}), 429) ],
        returns: double(code: "429", headers: { "retry-after" => "soon" })
      )

      expect { stream { |_t, *_| } }.to raise_error(Llm::AnthropicAdapter::LlmError)
      expect(adapter).to have_received(:sleep).with(described_class::RETRY_BACKOFF).at_least(:once)
    end

    it "never sleeps zero just because Retry-After said so" do
      stub_stream_fragments(
        [ stream_fragment(%({"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}), 429) ],
        returns: double(code: "429", headers: { "retry-after" => "0" })
      )

      expect { stream { |_t, *_| } }.to raise_error(Llm::AnthropicAdapter::LlmError)
      expect(adapter).not_to have_received(:sleep).with(0)
      expect(adapter).to have_received(:sleep).with(described_class::RETRY_BACKOFF).at_least(:once)
    end

    it "treats a non-numeric response code as an unknown status, not a failure" do
      stub_stream_fragments([ stream_fragment("data: {}\n\n", "OK") ], returns: double(code: "OK"))

      expect { stream { |_t, *_| } }.not_to raise_error
    end

    it "skips a malformed SSE line and keeps streaming the well-formed ones" do
      good = { type: "content_block_delta", delta: { type: "text_delta", text: "kept" } }.to_json
      stub_body("data: {not valid json\n\ndata: #{good}\n\n")

      result = stream { |_t, *_| }
      expect(result[:content]).to eq("kept")
    end

    it "normalizes a max_tokens stop reason to length so truncation stays provider-agnostic" do
      sse = [
        { type: "content_block_delta", delta: { type: "text_delta", text: "half" } }.to_json,
        { type: "message_delta", delta: { stop_reason: "max_tokens" } }.to_json
      ].map { |e| "data: #{e}\n\n" }.join
      stub_body(sse)

      result = stream { |_t, *_| }
      expect(result[:finish_reason]).to eq("length")
    end

    it "does not classify provider content beyond the bounded error prefix" do
      prefix = %({"type":"error","error":{"type":"invalid_request_error","message":")
      huge = prefix + ("x" * described_class::ERROR_CLASSIFY_LIMIT) + "Your credit balance is too low\"}}"
      stub_stream_fragments([ stream_fragment(huge, 400), stream_fragment("tail", 400) ],
                            returns: double(code: "400"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_request_rejected)
          expect(e.message).not_to include("credit balance")
        }
      expect(HTTParty).to have_received(:post).once
    end
  end
end
