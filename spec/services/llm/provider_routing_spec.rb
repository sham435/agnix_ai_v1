# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

require "rails_helper"

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
RSpec.describe Llm::Client, "provider architecture routing" do
  around do |example|
    original_env = ENV.to_hash
    ENV.delete("GROQ_BASE_URL")
    ENV.delete("CEREBRAS_BASE_URL")
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    ENV.replace(original_env)
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:organization) { create(:organization) }
  let(:api_key) { "test-only-custom-provider-key" }
  let(:base_url) { "https://custom.example.test/v1" }
  let(:custom_config) do
    {
      "base_url" => base_url, "auth_mode" => "bearer", "max_retries" => 0,
      "models" => {
        "chat-model" => {
          "api_family" => "chat_completions", "max_output_tokens" => 64,
          "supported_parameters" => %w[temperature max_tokens top_p tools seed logprobs],
          "options" => { "temperature" => 0.1, "max_tokens" => 999, "seed" => 7, "logprobs" => true,
                         "messages" => [ { "role" => "user", "content" => "must-not-override" } ],
                         "response_format" => { "type" => "json_object" } }
        },
        "responses-model" => {
          "api_family" => "responses", "max_output_tokens" => 32,
          "supported_parameters" => %w[temperature max_output_tokens tools top_p seed text store],
          "options" => { "temperature" => 0.1, "max_output_tokens" => 999, "max_tokens" => 999,
                         "seed" => 11, "store" => false, "text" => { "format" => { "type" => "json_object" } },
                         "input" => [ { "role" => "user", "content" => "must-not-override" } ] }
        }
      }
    }
  end
  let!(:custom_integration) do
    create(:tool_integration, organization: organization, provider: "custom-acme", name: "Custom test provider",
                              credentials: { "api_key" => api_key }, config: custom_config)
  end

  before do
    # DNS/SSRF policy is covered in provider_endpoint_spec; these examples exercise routing and payloads.
    allow(Llm::ProviderEndpoint).to receive(:enforce_destination!)
  end

  def custom_client(model, max_tokens: 1000)
    connection = Llm::ProviderConnection.new(provider: "custom-acme", integration: custom_integration, model: model)
    described_class.new(provider: "custom-acme", model: model, connection: connection,
                        max_tokens: max_tokens, top_p: 0.9)
  end

  def messages_with_tool_history
    [
      { role: "user", content: "Weather?" },
      { role: "assistant", content: "", tool_calls: [
        { id: "call-1", type: "function", function: { name: "weather", arguments: "{}" } }
      ] },
      { role: "tool", tool_call_id: "call-1", content: "sunny" }
    ]
  end

  def tools
    [ { name: "weather", description: "Get weather", parameters: { "type" => "object", "properties" => {} } } ]
  end

  describe "custom per-model routing" do
    it "uses Chat Completions for a chat model, filters parameters, caps output, and normalizes the reply" do
      url = "#{base_url}/chat/completions"
      stub_request(:post, url).to_return(status: 200, body: {
        choices: [ {
          finish_reason: "tool_calls",
          message: { content: "Chat OK", tool_calls: [
            { id: "call-2", type: "function", function: { name: "weather", arguments: '{"city":"Paris"}' } }
          ] }
        } ],
        usage: { completion_tokens: 11 }
      }.to_json)

      result = custom_client("chat-model").chat(messages: messages_with_tool_history, tools: tools)

      expect(a_request(:post, url).with(headers: { "Authorization" => "Bearer #{api_key}" }) do |request|
        body = JSON.parse(request.body)
        expect(body).to include("model" => "chat-model", "temperature" => 0.7, "max_tokens" => 64,
                                "top_p" => 0.9, "seed" => 7, "logprobs" => true)
        expect(body["messages"]).to eq([
          { "role" => "user", "content" => "Weather?" },
          { "role" => "assistant", "content" => "", "tool_calls" => [
            { "id" => "call-1", "type" => "function", "function" => { "name" => "weather", "arguments" => "{}" } }
          ] },
          { "role" => "tool", "content" => "sunny", "tool_call_id" => "call-1" }
        ])
        expect(body["tools"]).to eq([
          { "type" => "function", "function" => { "name" => "weather", "description" => "Get weather",
                                                    "parameters" => { "type" => "object", "properties" => {} } } }
        ])
        expect(body).not_to have_key("input")
        expect(body).not_to have_key("max_output_tokens")
        expect(body).not_to have_key("response_format")
        true
      end).to have_been_made.once
      expect(result).to eq(content: "Chat OK", tokens: 11, finish_reason: "tool_calls", tool_calls: [
        { id: "call-2", type: "function", function: { "name" => "weather", "arguments" => '{"city":"Paris"}' } }
      ])
    end

    it "uses Responses for a responses model, normalizes tool history, filters parameters, and caps output" do
      url = "#{base_url}/responses"
      stub_request(:post, url).to_return(status: 200, body: {
        status: "completed",
        output: [
          { type: "message", content: [ { type: "output_text", text: "Responses OK" } ] },
          { type: "function_call", call_id: "call-3", name: "weather", arguments: '{"city":"Rome"}' }
        ],
        usage: { output_tokens: 12 }
      }.to_json)

      result = custom_client("responses-model").chat(messages: messages_with_tool_history, tools: tools)

      expect(a_request(:post, url).with do |request|
        body = JSON.parse(request.body)
        expect(body).to include("model" => "responses-model", "temperature" => 0.7, "max_output_tokens" => 32,
                                "top_p" => 0.9, "seed" => 11, "store" => false,
                                "text" => { "format" => { "type" => "json_object" } })
        expect(body["input"]).to eq([
          { "role" => "user", "content" => "Weather?" },
          { "role" => "assistant", "content" => "" },
          { "type" => "function_call", "call_id" => "call-1", "name" => "weather", "arguments" => "{}" },
          { "type" => "function_call_output", "call_id" => "call-1", "output" => "sunny" }
        ])
        expect(body["tools"]).to eq([
          { "type" => "function", "name" => "weather", "description" => "Get weather",
            "parameters" => { "type" => "object", "properties" => {} } }
        ])
        expect(body).not_to have_key("messages")
        expect(body).not_to have_key("max_tokens")
        true
      end).to have_been_made.once
      expect(result).to eq(content: "Responses OK", tokens: 12, finish_reason: "tool_calls", tool_calls: [
        { id: "call-3", type: "function", function: { "name" => "weather", "arguments" => '{"city":"Rome"}' } }
      ])
    end
  end

  describe "registered provider routing through an organization connection" do
    %w[groq cerebras].each do |provider|
      it "routes #{provider} only to its registered Chat Completions endpoint" do
        definition = Llm::ProviderRegistry::DEFINITIONS.fetch(provider)
        create(:tool_integration, organization: organization, provider: provider,
                                  credentials: { "api_key" => "test-only-provider-key" })
        connection = Llm::ProviderConnection.resolve(organization: organization, provider: provider,
                                                     model: "test-model")
        client = described_class.new(provider: provider, model: "test-model", connection: connection)
        url = "#{definition[:base_url]}/chat/completions"
        stub_request(:post, url).to_return(status: 200, body: {
          choices: [ { message: { content: "OK" }, finish_reason: "stop" } ], usage: { completion_tokens: 2 }
        }.to_json)

        expect(client.chat(messages: [ { role: "user", content: "hi" } ])[:content]).to eq("OK")
        expect(a_request(:post, url).with(body: hash_including("model" => "test-model"))).to have_been_made.once
        expect(a_request(:post, "#{definition[:base_url]}/responses")).not_to have_been_made
      end
    end
  end

  describe "sanitized typed failures" do
    {
      401 => { "type" => "invalid_api_key", "code" => "bad-key" },
      402 => { "type" => "insufficient_quota", "code" => "quota-exhausted" },
      429 => { "type" => "rate_limit_exceeded", "code" => "slow-down" }
    }.each do |status, metadata|
      it "maps HTTP #{status} without exposing the raw body, key, or endpoint" do
        url = "#{base_url}/chat/completions"
        raw_marker = "RAW-UPSTREAM-BODY-DO-NOT-LEAK"
        stub_request(:post, url).to_return(status: status, headers: { "X-Request-Id" => "req-test-only" }, body: {
          error: metadata.merge("message" => raw_marker, "endpoint" => url, "api_key" => api_key)
        }.to_json)
        expected_code = { 401 => "provider_authentication_failed", 402 => "provider_credit_insufficient",
                          429 => "provider_rate_limited" }.fetch(status)

        expect { custom_client("chat-model").chat(messages: [ { role: "user", content: "hi" } ]) }
          .to raise_error(Llm::ProviderError) { |error|
            expect(error.code).to eq(expected_code)
            expect(error.status).to eq(status)
            expect(error.provider_error_type).to eq(metadata["type"])
            expect(error.provider_error_code).to eq(metadata["code"])
            expect(error.request_id).to eq("req-test-only")
            expect(error.retryable?).to eq(status == 429)
            expect(error.message).not_to include(raw_marker, api_key, base_url)
          }
        expect(a_request(:post, url)).to have_been_made.once
      end
    end
  end
end

# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
