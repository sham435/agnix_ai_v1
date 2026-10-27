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
    # Chain of thought is never answer text. A reply that spent its whole
    # budget thinking comes back EMPTY, which AgentStreamJob records as
    # metadata["empty_response"] and the UI states plainly - instead of
    # pasting the model's private monologue into the user's bubble, which is
    # what the old reasoning->content fallback did (reproduced live on a
    # truncated Recursive Flint turn).
    it "returns an empty answer when only reasoning_content (llama.cpp) is present" do
      stub_response(
        choices: [ {
          finish_reason: "length",
          message: { role: "assistant", content: "", reasoning_content: "PONG sent as reasoning" }
        } ],
        usage: { completion_tokens: 10 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "Reply PONG" } ], tools: [],
                                 temperature: 0.7, max_tokens: 100)
      expect(result[:content]).to eq("")
      expect(result[:content]).not_to include("PONG")
    end

    it "returns an empty answer when only reasoning (OpenRouter style) is present" do
      stub_response(
        choices: [ {
          finish_reason: "stop",
          message: { role: "assistant", content: nil, reasoning: "openrouter reasoning body" }
        } ],
        usage: { completion_tokens: 10 }
      )

      result = adapter.sync_chat(messages: [ { role: "user", content: "hello" } ], tools: [],
                                 temperature: 0.7, max_tokens: 100)
      expect(result[:content]).to eq("")
      expect(result[:content]).not_to include("reasoning")
      # The server's usage still counts the tokens it really generated.
      expect(result[:tokens]).to eq(10)
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

    it "leaves the answer empty when the stream only carried reasoning_content" do
      stub_stream([
        { choices: [ { index: 0, delta: { reasoning_content: "only thinking here" } } ] }.to_json,
        { choices: [], usage: { completion_tokens: 20 } }.to_json
      ])

      kinds = []
      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 100) do |_piece, _full, _tcs, kind|
        kinds << kind
      end

      # The thinking is not smuggled into the reply; the caller sees a blank
      # answer and reports it as an empty response.
      expect(result[:content]).to eq("")
      expect(kinds).to eq([ "reasoning" ])
    end

    it "treats OpenRouter-style delta reasoning as thinking, not as content" do
      stub_stream([
        { choices: [ { index: 0, delta: { reasoning: "Flint is pondering" } } ] }.to_json,
        { choices: [ { index: 0, delta: { content: "FLINT-LIVE-OK" } } ] }.to_json,
        { choices: [], usage: { completion_tokens: 30 } }.to_json
      ])

      frames = []
      result = adapter.stream_chat(messages: [ { role: "user", content: "hi" } ], tools: [],
                                   temperature: 0.7, max_tokens: 100) do |piece, _full, _tcs, kind|
        frames << [ kind, piece ]
      end

      expect(frames).to eq([ [ "reasoning", "Flint is pondering" ], [ "content", "FLINT-LIVE-OK" ] ])
      expect(result[:content]).to eq("FLINT-LIVE-OK")
      expect(result[:tokens]).to eq(30)
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
