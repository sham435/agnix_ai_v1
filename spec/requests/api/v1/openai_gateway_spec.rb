# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "API v1 OpenAI gateway", type: :request do
  let(:user) { create(:user) }
  let(:bonsai_url) { "#{ENV.fetch('BONSAI2_BASE_URL', 'http://127.0.0.1:8080/v1')}/chat/completions" }
  let(:completion) do
    {
      id: "chatcmpl-test", object: "chat.completion", created: 1, model: "bonsai-2-27b",
      choices: [ { index: 0, message: { role: "assistant", content: "hello" }, finish_reason: "stop" } ],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
    }
  end

  it "refuses unauthenticated callers before any provider request" do
    get "/api/v1/openai/models"
    expect(response).to have_http_status(:unauthorized)

    body = { model: "bonsai-2-27b", messages: [ { role: "user", content: "hi" } ] }.to_json
    post "/api/v1/openai/chat/completions", params: body, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unprocessable_content)

    get "/api/v1/csrf"
    token = JSON.parse(response.body)["token"]
    post "/api/v1/openai/chat/completions", params: body, headers: { "Content-Type" => "application/json", "X-CSRF-Token" => token }
    expect(response).to have_http_status(:unauthorized)
    expect(a_request(:post, bonsai_url)).not_to have_been_made
  end

  it "serves the model list to a signed-in caller" do
    api_login(user)
    get "/api/v1/openai/models"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["data"].first["id"]).to eq(ENV.fetch("BONSAI_MODEL", "bonsai-2-27b"))
  end

  it "proxies a signed-in completion with thinking disabled and the OpenAI contract intact" do
    stub_request(:post, bonsai_url).to_return(status: 200, body: completion.to_json, headers: { "Content-Type" => "application/json" })
    api_login(user)
    post "/api/v1/openai/chat/completions",
         params: { messages: [ { role: "user", content: "hi" } ], max_tokens: 16 }.to_json,
         headers: api_headers.merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(JSON.parse(completion.to_json))
    expect(a_request(:post, bonsai_url).with { |req| JSON.parse(req.body)["chat_template_kwargs"] == { "enable_thinking" => false } }).to have_been_made.once
  end

  it "leaves unrelated authenticated API endpoints working" do
    api_login(user)
    get "/api/v1/capabilities"
    expect(response).to have_http_status(:ok)
  end
end
