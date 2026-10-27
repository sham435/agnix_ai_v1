# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Llm::OpenaiAdapter do
  let(:adapter) { described_class.new(api_key: "test-key", model: "bonsai-2-27b") }

  def stub_response(body)
    response = instance_double(HTTParty::Response, success?: true, body: body.to_json)
    allow(HTTParty).to receive(:post).and_return(response)
  end

  describe "reasoning-only responses" do
    it "falls back to reasoning_content (llama.cpp) when content is blank" do
      stub_response(
        choices: [ {
          finish_reason: "length",
          message: { role: "assistant", content: "", reasoning_content: "PONG sent as reasoning" }
        } ],
        usage: { completion_tokens: 10 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "Reply PONG" } ], tools: [],
                                 temperature: 0.7, max_tokens: 100)
      expect(result[:content]).to include("PONG")
      expect(result[:content]).not_to be_blank
    end

    it "falls back to reasoning (OpenRouter style) when content is blank" do
      stub_response(
        choices: [ {
          finish_reason: "stop",
          message: { role: "assistant", content: nil, reasoning: "openrouter reasoning body" }
        } ],
        usage: { completion_tokens: 10 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "hello" } ], tools: [],
                                 temperature: 0.7, max_tokens: 100)
      expect(result[:content]).to eq("openrouter reasoning body")
    end

    it "prefers real content over reasoning" do
      stub_response(
        choices: [ {
          finish_reason: "stop",
          message: { role: "assistant", content: "visible text", reasoning_content: "internal" }
        } ],
        usage: { completion_tokens: 10 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                 temperature: 0.7, max_tokens: 100)
      expect(result[:content]).to eq("visible text")
    end

    it "still parses tool calls alongside blank content" do
      stub_response(
        choices: [ {
          finish_reason: "tool_calls",
          message: {
            role: "assistant",
            content: "",
            tool_calls: [ { id: "call_1", type: "function",
                           function: { name: "run_command", arguments: '{"command":"ls"}' } } ]
          }
        } ],
        usage: { completion_tokens: 30 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "list files" } ], tools: [],
                                 temperature: 0.7, max_tokens: 200)
      expect(result[:tool_calls]).to be_present
      expect(result[:tool_calls].first[:function]["name"]).to eq("run_command")
      expect(result[:finish_reason]).to eq("tool_calls")
    end
  end

  describe "#stream_chat" do
    # Forward the caller's block so it receives each SSE data line, mimicking
    # HTTParty's stream_body block form.
    def stub_stream(payloads)
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        payloads.each { |p| blk&.call("data: #{p}\n\n") }
        blk&.call("data: [DONE]\n\n")
      end
    end

    before { allow(adapter).to receive(:sleep) } # keep retry spec fast

    it "reports the server usage.completion_tokens, not a chars/4 estimate" do
      stub_stream([
        { choices: [ { index: 0, delta: { reasoning_content: "thinking" } } ] }.to_json,
        { choices: [ { index: 0, delta: { content: "Hi there!" } } ] }.to_json,
        { choices: [], usage: { completion_tokens: 57 } }.to_json
      ])

      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 100) { |_c, _f, _t| }
      expect(result[:content]).to eq("Hi there!")
      # "Hi there!" is 9 chars -> estimate would be 3; must be the real 57.
      expect(result[:tokens]).to eq(57)
    end

    it "surfaces reasoning_content when the stream yields no visible content" do
      stub_stream([
        { choices: [ { index: 0, delta: { reasoning_content: "only thinking here" } } ] }.to_json,
        { choices: [], usage: { completion_tokens: 20 } }.to_json
      ])

      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 100) { |_c, _f, _t| }
      expect(result[:content]).to eq("only thinking here")
      expect(result[:content]).not_to be_blank
    end

    it "retries once on a transient connection error before anything streamed" do
      calls = 0
      ok_chunk = { choices: [ { index: 0, delta: { content: "ok" } } ] }.to_json
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        calls += 1
        raise Errno::ECONNREFUSED if calls == 1

        blk&.call("data: #{ok_chunk}\n\n")
        blk&.call("data: [DONE]\n\n")
      end

      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 100) { |_c, _f, _t| }
      expect(result[:content]).to eq("ok")
      expect(calls).to eq(2)
    end

    it "yields the delta kind so callers can separate reasoning from content" do
      payloads = [
        { choices: [ { index: 0, delta: { reasoning_content: "thinking hard" } } ] }.to_json,
        { choices: [ { index: 0, delta: { content: "Hi" } } ] }.to_json,
        { choices: [], usage: { completion_tokens: 4 } }.to_json
      ]
      allow(HTTParty).to receive(:post) do |_url, _opts, &blk|
        payloads.each { |p| blk&.call("data: #{p}\n\n") }
        blk&.call("data: [DONE]\n\n")
      end

      kinds = []
      pieces = []
      adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 100) do |piece, _full, _tcs, kind|
        kinds << kind
        pieces << piece
      end

      expect(kinds).to eq([ "reasoning", "content" ])
      expect(pieces).to eq([ "thinking hard", "Hi" ])
    end
  end

  describe "connection fast-fail" do
    before { allow(adapter).to receive(:sleep) }

    it "retries the sync path only briefly, then raises an actionable error naming the endpoint" do
      posts = 0
      allow(HTTParty).to receive(:post) do
        posts += 1
        raise Errno::ECONNREFUSED
      end

      expect do
        adapter.sync_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                          temperature: 0.7, max_tokens: 10)
      end.to raise_error(Llm::OpenaiAdapter::LlmError, /Could not reach the model server/)

      # Bounded: initial + MAX_CONNECT_RETRIES(1) = 2 attempts — never a long
      # retry loop against a dead port.
      expect(posts).to eq(2)
    end

    it "retries the streaming path only briefly when nothing streamed yet" do
      posts = 0
      allow(HTTParty).to receive(:post) do
        posts += 1
        raise Errno::ECONNREFUSED
      end

      expect do
        adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                            temperature: 0.7, max_tokens: 10) { |_c, _f, _t, _k| }
      end.to raise_error(Llm::OpenaiAdapter::LlmError, /Could not reach the model server/)

      expect(posts).to eq(2)
    end
  end
end
