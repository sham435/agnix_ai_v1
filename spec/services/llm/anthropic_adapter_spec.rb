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
end
