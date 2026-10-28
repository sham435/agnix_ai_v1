# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Llm::AnthropicAdapter do
  let(:adapter) { described_class.new(api_key: "test-key", model: "claude-sonnet-4-6") }

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
end
