# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "Provider response normalization" do
  let(:chat) { Llm::OpenaiAdapter.new(api_key: "test-only-key", model: "test-model") }
  let(:responses) { Llm::ResponsesAdapter.new(api_key: "test-only-key", model: "test-model") }
  let(:messages) { [ { role: "user", content: "hello" } ] }

  def stub_stream(payloads)
    allow(HTTParty).to receive(:post) do |_url, _options, &block|
      payloads.each { |payload| block.call("data: #{payload}\n\n") }
      double(code: "200", headers: {})
    end
  end

  def stream(adapter, &block)
    adapter.stream_chat(messages: messages, tools: [], temperature: 0.7, max_tokens: 100, &block)
  end

  [ Llm::OpenaiAdapter, Llm::ResponsesAdapter ].each do |adapter_class|
    it "filters tool parameters for #{adapter_class} when tool support is explicitly false" do
      connection = Llm::ProviderConnection.new(provider: "openai", api_key: "test-only-key", model: "test-model",
        model_config: { "supports_tools" => false,
                        "options" => { "tool_choice" => "auto", "parallel_tool_calls" => true } })
      adapter = adapter_class.new(api_key: "test-only-key", model: "test-model", connection: connection)
      body = adapter.send(:build_request_body, messages, [], 0.7, 100)

      expect(body.keys).not_to include(:tools, :tool_choice, :parallel_tool_calls)
      expect { adapter.send(:build_request_body, messages, [ { name: "weather", parameters: {} } ], 0.7, 100) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("provider_tool_incompatible") }
    end

    it "preserves structured multimodal input for #{adapter_class}" do
      content = [ { type: "text", text: "Describe this" },
                  { type: "image_url", image_url: { url: "data:image/png;base64,test-only" } } ]
      body = adapter_class.new(api_key: "test-only-key", model: "test-model")
        .send(:build_request_body, [ { role: "user", content: content } ], [], 0.7, 100)

      expect(body.fetch(adapter_class == Llm::ResponsesAdapter ? :input : :messages).first[:content]).to eq(content)
    end
  end

  describe "Chat Completions SSE" do
    before { allow(chat).to receive(:sleep) }

    it "requires the DONE sentinel even after visible content" do
      stub_stream([ { choices: [ { delta: { content: "partial" } } ] }.to_json ])

      expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("provider_stream_interrupted")
        expect(error.retryable?).to be(false)
      }
      expect(HTTParty).to have_received(:post).once
    end

    it "classifies malformed SSE JSON without leaking it" do
      stub_stream([ '{"choices":' ])

      expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
        expect(error.message).not_to include("choices")
      }
    end

    it "rejects a malformed inline error instead of raising a type error" do
      stub_stream([ { error: "upstream denied" }.to_json ])

      expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
        expect(error.message).not_to include("upstream denied")
      }
    end

    it "sorts and compacts valid sparse tool-call indices" do
      stub_stream([
        { choices: [ { delta: { tool_calls: [
          { index: 7, id: "call-7", function: { name: "seven", arguments: "{}" } },
          { index: 2, id: "call-2", function: { name: "two", arguments: "{}" } }
        ] } } ] }.to_json,
        "[DONE]"
      ])

      result = stream(chat)
      expect(result[:tool_calls].pluck(:id)).to eq([ "call-2", "call-7" ])
      expect(result[:tool_calls].pluck(:function)).to eq([
        { "name" => "two", "arguments" => "{}" }, { "name" => "seven", "arguments" => "{}" }
      ])
    end

    it "rejects non-string content deltas instead of coercing them" do
      stub_stream([ { choices: [ { delta: { content: { text: "not-a-string" } } } ] }.to_json, "[DONE]" ])

      expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end

    it "rejects non-string streamed function arguments" do
      stub_stream([
        { choices: [ { delta: { tool_calls: [
          { index: 0, id: "call-1", function: { name: "weather", arguments: { city: "Paris" } } }
        ] } } ] }.to_json,
        "[DONE]"
      ])

      expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end

    [ -1, 10_001, "not-an-index", 1.5, true ].each do |index|
      it "rejects invalid tool-call index #{index.inspect}" do
        stub_stream([
          { choices: [ { delta: { tool_calls: [
            { index: index, id: "call-1", function: { name: "tool", arguments: "{}" } }
          ] } } ] }.to_json,
          "[DONE]"
        ])

        expect { stream(chat) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("invalid_provider_response")
        }
        expect(HTTParty).to have_received(:post).once
      end
    end
  end

  describe "Responses SSE" do
    before { allow(responses).to receive(:sleep) }

    it "normalizes text, usage, and a completed event" do
      stub_stream([
        { type: "response.output_text.delta", delta: "Hello" }.to_json,
        { type: "response.completed", response: {
          status: "completed", output: [], usage: { output_tokens: 9 }
        } }.to_json
      ])

      expect(stream(responses)).to eq(content: "Hello", tool_calls: [], tokens: 9, finish_reason: "stop")
    end

    it "normalizes streamed function arguments" do
      stub_stream([
        { type: "response.output_item.added", output_index: 0, item: {
          type: "function_call", id: "item-1", call_id: "call-1", name: "weather", arguments: ""
        } }.to_json,
        { type: "response.function_call_arguments.delta", item_id: "item-1", delta: '{"city":"Paris"}' }.to_json,
        { type: "response.completed", response: {
          status: "completed", output: [ {
            type: "function_call", id: "item-1", call_id: "call-1", name: "weather", arguments: '{"city":"Paris"}'
          } ], usage: { output_tokens: 12 }
        } }.to_json
      ])

      result = stream(responses)
      expect(result[:finish_reason]).to eq("tool_calls")
      expect(result[:tool_calls]).to eq([ {
        id: "call-1", type: "function", function: { "name" => "weather", "arguments" => '{"city":"Paris"}' }
      } ])
    end

    it "sorts and compacts valid sparse output indices" do
      stub_stream([
        { type: "response.output_item.added", output_index: 7, item: {
          type: "function_call", id: "item-7", call_id: "call-7", name: "seven", arguments: ""
        } }.to_json,
        { type: "response.output_item.added", output_index: 2, item: {
          type: "function_call", id: "item-2", call_id: "call-2", name: "two", arguments: ""
        } }.to_json,
        { type: "response.function_call_arguments.delta", item_id: "item-7", delta: "{}" }.to_json,
        { type: "response.function_call_arguments.delta", item_id: "item-2", delta: "{}" }.to_json,
        { type: "response.incomplete", response: {
          status: "incomplete", incomplete_details: { reason: "max_output_tokens" }
        } }.to_json
      ])

      result = stream(responses)
      expect(result[:tool_calls].pluck(:id)).to eq([ "call-2", "call-7" ])
      expect(result[:tool_calls].pluck(:function)).to eq([
        { "name" => "two", "arguments" => "{}" }, { "name" => "seven", "arguments" => "{}" }
      ])
    end

    [ -1, 10_001, "not-an-index", 1.5, true ].each do |index|
      it "rejects invalid output index #{index.inspect} even when an item ID is present" do
        stub_stream([
          { type: "response.output_item.added", output_index: index, item: {
            type: "function_call", id: "item-1", call_id: "call-1", name: "tool", arguments: ""
          } }.to_json,
          { type: "response.incomplete", response: { status: "incomplete" } }.to_json
        ])

        expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("invalid_provider_response")
        }
        expect(HTTParty).to have_received(:post).once
      end
    end

    it "rejects non-string text deltas instead of coercing them" do
      stub_stream([ { type: "response.output_text.delta", delta: { text: "not-a-string" } }.to_json ])

      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end

    it "bounds newly streamed function-call items" do
      payloads = Array.new(Llm::OpenaiAdapter::MAX_TOOL_CALLS + 1) do |index|
        { type: "response.output_item.added", output_index: index, item: {
          type: "function_call", id: "item-#{index}", call_id: "call-#{index}", name: "weather", arguments: ""
        } }.to_json
      end
      stub_stream(payloads)

      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end

    it "requires a terminal Responses event" do
      stub_stream([ { type: "response.output_text.delta", delta: "partial" }.to_json ])

      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("provider_stream_interrupted")
        expect(error.retryable?).to be(false)
      }
      expect(HTTParty).to have_received(:post).once
    end

    it "classifies malformed SSE JSON" do
      stub_stream([ "not-json" ])

      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end

    it "preserves a typed inline error with a nonnumeric upstream status" do
      stub_stream([ { error: { type: "external_client_restricted", status: "denied" } }.to_json ])

      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("provider_external_client_restricted")
        expect(error.provider_error_type).to eq("external_client_restricted")
        expect(error.retryable?).to be(false)
      }
    end

    it "rejects malformed inline and terminal error payloads" do
      stub_stream([ { error: "denied" }.to_json ])
      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }

      stub_stream([ { type: "response.failed", response: "denied" }.to_json ])
      expect { stream(responses) }.to raise_error(Llm::ProviderError) { |error|
        expect(error.code).to eq("invalid_provider_response")
      }
    end
  end

  describe "HTTP error retries" do
    def http_response(status, body, headers = {})
      instance_double(HTTParty::Response, code: status, success?: status.between?(200, 299),
                      headers: headers, body: body.to_json)
    end

    def sync(adapter)
      adapter.sync_chat(messages: messages, tools: [], temperature: 0.7, max_tokens: 100)
    end

    it "honors Retry-After before retrying a Chat Completions rate limit" do
      allow(chat).to receive(:sleep)
      allow(HTTParty).to receive(:post).and_return(
        http_response(429, { error: { type: "rate_limit_error" } }, { "Retry-After" => "7" }),
        http_response(200, { choices: [ { message: { content: "ok" } } ] })
      )

      expect(sync(chat)[:content]).to eq("ok")
      expect(chat).to have_received(:sleep).with(7.0)
      expect(HTTParty).to have_received(:post).twice
    end

    it "honors Retry-After before retrying a Responses rate limit" do
      allow(responses).to receive(:sleep)
      allow(HTTParty).to receive(:post).and_return(
        http_response(429, { error: { type: "rate_limit_error" } }, { "Retry-After" => "9" }),
        http_response(200, { status: "completed", output: [ {
          type: "message", content: [ { type: "output_text", text: "ok" } ]
        } ] })
      )

      expect(sync(responses)[:content]).to eq("ok")
      expect(responses).to have_received(:sleep).with(9.0)
      expect(HTTParty).to have_received(:post).twice
    end

    {
      400 => [ "unsupported_parameter", "provider_parameter_unsupported" ],
      401 => [ "invalid_api_key", "provider_authentication_failed" ],
      403 => [ "external_client_restricted", "provider_external_client_restricted" ],
      404 => [ "model_not_found", "provider_model_not_found" ]
    }.each do |status, (upstream_type, code)|
      it "does not retry HTTP #{status}" do
        allow(chat).to receive(:sleep)
        allow(HTTParty).to receive(:post).and_return(
          http_response(status, { error: { type: upstream_type, message: "secret detail" } })
        )

        expect { sync(chat) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq(code)
          expect(error.message).not_to include("secret detail")
        }
        expect(chat).not_to have_received(:sleep)
        expect(HTTParty).to have_received(:post).once
      end
    end

    it "honors Retry-After before retrying a Chat Completions stream" do
      allow(chat).to receive(:sleep)
      calls = 0
      allow(HTTParty).to receive(:post) do |_url, _options, &block|
        calls += 1
        if calls == 1
          block.call(double(to_s: '{"error":{"type":"rate_limit_error"}}', code: 429,
                         headers: { "Retry-After" => "4" }))
          double(code: 429, headers: {})
        else
          block.call("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n")
          block.call("data: [DONE]\n\n")
          double(code: 200, headers: {})
        end
      end

      expect(stream(chat)[:content]).to eq("ok")
      expect(chat).to have_received(:sleep).with(4.0)
      expect(calls).to eq(2)
    end

    it "honors Retry-After before retrying a Responses stream" do
      allow(responses).to receive(:sleep)
      calls = 0
      allow(HTTParty).to receive(:post) do |_url, _options, &block|
        calls += 1
        if calls == 1
          block.call(double(to_s: '{"error":{"type":"rate_limit_error"}}', code: 429,
                         headers: { "Retry-After" => "6" }))
          double(code: 429, headers: {})
        else
          block.call("data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\n")
          block.call("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n")
          double(code: 200, headers: {})
        end
      end

      expect(stream(responses)[:content]).to eq("ok")
      expect(responses).to have_received(:sleep).with(6.0)
      expect(calls).to eq(2)
    end
  end

  describe "synchronous response validation" do
    def stub_sync(adapter, payload)
      allow(HTTParty).to receive(:post).and_return(instance_double(
        HTTParty::Response, success?: true, code: 200, headers: {}, body: payload.to_json
      ))
      adapter.sync_chat(messages: messages, tools: [], temperature: 0.7, max_tokens: 100)
    end

    it "rejects a missing or invalid Chat Completions message object" do
      [ nil, "assistant", [] ].each do |message|
        payload = { choices: [ { finish_reason: "stop", message: message }.compact ] }
        expect { stub_sync(chat, payload) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("invalid_provider_response")
        }
      end
    end

    it "rejects invalid Chat Completions content and tool-call containers" do
      [ { content: [ "not-a-string" ] }, { content: "", tool_calls: false } ].each do |message|
        expect { stub_sync(chat, choices: [ { message: message } ]) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("invalid_provider_response")
        }
      end
    end

    it "bounds synchronous Chat Completions tool calls" do
      calls = Array.new(Llm::OpenaiAdapter::MAX_TOOL_CALLS + 1) do |index|
        { id: "call-#{index}", type: "function", function: { name: "weather", arguments: "{}" } }
      end

      expect { stub_sync(chat, choices: [ { message: { content: "", tool_calls: calls } } ]) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
    end

    it "rejects missing, non-array, and malformed Responses output" do
      [ {}, { output: "invalid" }, { output: [ "invalid" ] },
         { output: [ { type: "message" } ] },
         { output: [ { type: "message", content: [ "invalid" ] } ] },
         { output: [ { type: "message", content: [ { type: "output_text", text: 7 } ] } ] } ].each do |payload|
        expect { stub_sync(responses, payload) }.to raise_error(Llm::ProviderError) { |error|
          expect(error.code).to eq("invalid_provider_response")
        }
      end
    end

    it "bounds synchronous Responses function calls" do
      calls = Array.new(Llm::OpenaiAdapter::MAX_TOOL_CALLS + 1) do |index|
        { type: "function_call", call_id: "call-#{index}", name: "weather", arguments: "{}" }
      end

      expect { stub_sync(responses, status: "completed", output: calls) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
    end

    [
      [ "missing name", nil, "{}" ],
      [ "non-string name", 7, "{}" ],
      [ "invalid name characters", "bad name", "{}" ],
      [ "missing arguments", "weather", nil ],
      [ "non-string arguments", "weather", { city: "Paris" } ]
    ].each do |label, name, arguments|
      it "rejects #{label} in both provider response families" do
        chat_call = { id: "call-1", type: "function", function: { name: name, arguments: arguments } }
        response_call = { type: "function_call", call_id: "call-1", name: name, arguments: arguments }

        expect { stub_sync(chat, choices: [ { message: { content: "", tool_calls: [ chat_call ] } } ]) }
          .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
        expect { stub_sync(responses, status: "completed", output: [ response_call ]) }
          .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
      end
    end

    it "rejects a malformed Chat Completions choice error" do
      allow(HTTParty).to receive(:post).and_return(instance_double(
        HTTParty::Response, success?: true, code: 200, headers: {}, body: { choices: [ { error: "denied" } ] }.to_json
      ))

      expect { chat.sync_chat(messages: messages, tools: [], temperature: 0.7, max_tokens: 100) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
    end

    it "rejects a failed Responses payload with a malformed error" do
      allow(HTTParty).to receive(:post).and_return(instance_double(
        HTTParty::Response, success?: true, code: 200, headers: {}, body: { status: "failed", error: "denied" }.to_json
      ))

      expect { responses.sync_chat(messages: messages, tools: [], temperature: 0.7, max_tokens: 100) }
        .to raise_error(Llm::ProviderError) { |error| expect(error.code).to eq("invalid_provider_response") }
    end
  end
end

# rubocop:enable RSpec/DescribeClass
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
