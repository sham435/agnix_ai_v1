# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Llm::AnthropicAdapter do
  let(:adapter) { described_class.new(api_key: "test-key", model: "claude-sonnet-4-6") }

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

    it "raises with the provider message when the response is a JSON error" do
      # A rejected request (out of credit, bad key, unknown model) comes back as
      # one error object instead of an SSE stream. Returning an empty body here
      # would record the turn as empty_response and the UI would tell the user to
      # rephrase, hiding the real cause.
      stub_body({
        type: "error",
        error: { type: "invalid_request_error",
                 message: "Your credit balance is too low to access the Anthropic API." }
      }.to_json)

      expect {
        adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                            temperature: 0.7, max_tokens: 20) { |_t, _f, _tc| }
      }.to raise_error(Llm::AnthropicAdapter::LlmError, /credit balance is too low/)
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

    it "raises with the status and the server's reason instead of returning empty" do
      stub_stream_fragments([
        stream_fragment(%({"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}), 529)
      ], returns: double(code: "529"))

      pieces = []
      expect { stream { |text, *_| pieces << text } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error.message).to include("HTTP 529", "overloaded_error", "Overloaded")
        }
      expect(pieces).to be_empty
    end

    it "treats a non-2xx HTML body as a failure, not as a buffered message" do
      # Previously this reached the buffered-response fallback as unparseable
      # text and finalized the turn with content "", blaming the model for a
      # gateway that never reached it.
      page = "<html>\n<head><title>502 Bad Gateway</title></head>\n<body>upstream gone</body>\n</html>"
      stub_stream_fragments([ stream_fragment(page, 502) ])

      pieces = []
      expect { stream { |text, *_| pieces << text } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |error|
          expect(error.message).to include("HTTP 502", "502 Bad Gateway", "upstream gone")
          expect(error.message).not_to include("\n")
        }
      expect(pieces).to be_empty
    end

    it "names the status when the error response has no body to show" do
      stub_stream_fragments([ stream_fragment("", 429) ])

      expect { stream }.to raise_error(Llm::AnthropicAdapter::LlmError, /HTTP 429 with no response body/)
    end

    it "reads the status from the completed response when no fragment is streamed" do
      allow(HTTParty).to receive(:post).and_return(double(code: "401"))

      expect { stream }.to raise_error(Llm::AnthropicAdapter::LlmError, /HTTP 401 with no response body/)
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

  # The provider's failure is now a typed error, not just prose: `code` names the
  # cause and `retryable` says whether redelivery can help. Classification must
  # catch the credit case even when Anthropic files it as a generic 400, because
  # that is exactly how an out-of-credit key surfaces.
  describe "typed provider errors" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "files a spending ceiling that arrives as a 400 invalid_request_error as credit, not a generic rejection" do
      stub_body({ type: "error",
                  error: { type: "invalid_request_error",
                           message: "Your credit balance is too low to access the Anthropic API." } }.to_json)

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) do |e|
        expect(e.code).to eq(:provider_credit_insufficient)
        expect(e.retryable?).to be(false)
        expect(e.message).to include("credit balance is too low")
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
          expect(e.message).to include("500")
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

  # An out-of-credit key surfaces as a 400; if its message runs longer than the
  # display cap the classifier must still see the full body, or it misfiles a
  # permanent billing fault as a generic request rejection.
  describe "classification robustness" do
    def stream(&blk)
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 20, &blk)
    end

    it "sniffs the credit cause from an error body larger than the display cap" do
      filler = "detail " * 120 # > MAX_ERROR_BODY so the display buffer would truncate
      body = { type: "error",
               error: { type: "invalid_request_error",
                        message: "#{filler}Your credit balance is too low to access the Anthropic API." } }.to_json
      expect(body.bytesize).to be > described_class::MAX_ERROR_BODY

      stub_stream_fragments([ stream_fragment(body, 400) ], returns: double(code: "400"))

      expect { stream { |_t, *_| } }
        .to raise_error(Llm::AnthropicAdapter::LlmError) { |e|
          expect(e.code).to eq(:provider_credit_insufficient)
          expect(e.retryable?).to be(false)
        }
    end
  end
end
