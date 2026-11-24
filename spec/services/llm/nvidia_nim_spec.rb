# frozen_string_literal: true

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
# rubocop:disable RSpec/SpecFilePathFormat, RSpec/DescribeMethod

require "rails_helper"

RSpec.describe Llm::Client, "NVIDIA NIM integration" do
  around do |example|
    original_env = ENV.to_hash
    ENV.delete("NVIDIA_NIM_API_KEY")
    ENV.delete("NVIDIA_NIM_BASE_URL")
    WebMock.disable_net_connect!(allow_localhost: false)
    example.run
  ensure
    ENV.replace(original_env)
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  let(:organization) { create(:organization) }
  let(:api_key) { "test-only-nvidia-organization-key" }
  let(:environment_key) { "test-only-nvidia-environment-key" }
  let(:rails_key) { "test-only-nvidia-rails-key" }
  let(:model_id) { "nvidia/nemotron-3.5-lightning-30b-a3b" }
  let(:url) { "https://integrate.api.nvidia.com/v1/chat/completions" }
  let!(:integration) do
    create(:tool_integration, organization: organization, provider: "nvidia_nim", credentials: { "api_key" => api_key },
                              config: { "max_retries" => 0, "models" => {
                                model_id => { "api_family" => "chat_completions",
                                              "supports_streaming" => true, "supports_tools" => true }
                              } })
  end
  let(:connection) { Llm::ProviderConnection.resolve(organization: organization, provider: "nvidia_nim", model: model_id) }
  let(:client) { described_class.new(provider: "nvidia_nim", model: model_id, connection: connection, max_tokens: 32) }
  let(:messages) { [ { role: "user", content: "Weather?" } ] }
  let(:tools) do
    [ { name: "weather", description: "Get weather", parameters: { "type" => "object", "properties" => {} } } ]
  end

  before do
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia_nim, :api_key).and_return(rails_key)
  end

  it "registers the exact name, endpoint, manual-only discovery policy, and Chat Completions family" do
    definition = Llm::ProviderRegistry::DEFINITIONS.fetch("nvidia_nim")

    expect(definition).to include(name: "NVIDIA NIM", base_url: "https://integrate.api.nvidia.com/v1",
      env_key: "NVIDIA_NIM_API_KEY", discovery: "none", manual_only: true, api_families: %w[chat_completions])
    expect(Llm::ProviderRegistry.name("nvidia_nim")).to eq("NVIDIA NIM")
    expect(Llm::ProviderRegistry.default_api_family("nvidia_nim")).to eq("chat_completions")
    expect(Llm::ProviderRegistry.api_family?("nvidia_nim", "responses")).to be(false)
    expect(Llm::ProviderRegistry.example_model_ids("nvidia_nim")).to eq(%w[
      nvidia/nemotron-3.5-lightning-30b-a3b nvidia/nemotron-3.5-bolt-e4b
      deepseek-ai/deepseek-v4-flash meta/llama-3.3-70b-instruct
    ])
  end

  it "resolves credentials in organization, environment, then Rails credentials order" do
    ENV["NVIDIA_NIM_API_KEY"] = environment_key

    expect(connection.api_key).to eq(api_key)
    expect(connection.base_url).to eq("https://integrate.api.nvidia.com/v1")
    expect(connection.endpoint_for("chat/completions")).to eq(url)

    integration.update!(credentials: {})
    expect(Llm::ProviderConnection.resolve(organization: organization, provider: "nvidia_nim", model: model_id).api_key)
      .to eq(environment_key)

    ENV.delete("NVIDIA_NIM_API_KEY")
    expect(Llm::ProviderRegistry.credentials_key("nvidia_nim")).to eq(rails_key)
    expect(Llm::ProviderConnection.resolve(organization: organization, provider: "nvidia_nim", model: model_id).api_key)
      .to eq(rails_key)
    expect(a_request(:any, %r{\Ahttps://integrate\.api\.nvidia\.com})).not_to have_been_made
  end

  it "streams content and tool calls through the existing Chat Completions adapter" do
    events = [
      { choices: [ { index: 0, delta: { content: "OK" } } ] },
      { choices: [ { index: 0, delta: { tool_calls: [ { index: 0, id: "call-nim-1", type: "function",
        function: { name: "weather", arguments: '{"city":"Paris"}' } } ] }, finish_reason: "tool_calls" } ] },
      { choices: [], usage: { completion_tokens: 7 } }
    ]
    body = events.map { |event| "data: #{event.to_json}\n\n" }.join + "data: [DONE]\n\n"
    stub_request(:post, url).with(headers: { "Authorization" => "Bearer #{api_key}" }) do |request|
      payload = JSON.parse(request.body)
      expect(payload).to include("model" => model_id, "stream" => true,
        "messages" => [ { "role" => "user", "content" => "Weather?" } ])
      expect(payload["tools"]).to eq([ { "type" => "function", "function" => {
        "name" => "weather", "description" => "Get weather", "parameters" => { "type" => "object", "properties" => {} }
      } } ])
      expect(payload).not_to have_key("input")
      true
    end.to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: body)
    frames = []

    result = client.chat(messages: messages, tools: tools, stream: true) do |piece, _full, _calls, kind|
      frames << [ kind, piece ]
    end

    expect(frames).to eq([ [ "content", "OK" ] ])
    expect(result).to include(content: "OK", tokens: 7, finish_reason: "tool_calls")
    expect(result[:tool_calls]).to eq([ { id: "call-nim-1", type: "function",
      function: { "name" => "weather", "arguments" => '{"city":"Paris"}' } } ])
    expect(a_request(:post, url)).to have_been_made.once
    expect(a_request(:post, "https://integrate.api.nvidia.com/v1/responses")).not_to have_been_made
    expect(a_request(:get, "https://integrate.api.nvidia.com/v1/models")).not_to have_been_made
  end

  it "surfaces sanitized typed provider errors through the generic adapter" do
    raw_marker = "RAW-NVIDIA-RATE-LIMIT-DO-NOT-LEAK"
    stub_request(:post, url).to_return(status: 429, body: {
      error: { type: "rate_limit_exceeded", message: raw_marker, api_key: api_key }
    }.to_json)

    expect { client.chat(messages: messages, tools: []) }.to raise_error(Llm::ProviderError) { |error|
      expect(error.code).to eq("provider_rate_limited")
      expect(error.status).to eq(429)
      expect(error.retryable?).to be(true)
      expect(error.message).not_to include(raw_marker, api_key, "integrate.api.nvidia.com")
    }
    expect(a_request(:post, url)).to have_been_made.once
  end
end

# rubocop:enable RSpec/SpecFilePathFormat, RSpec/DescribeMethod
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
