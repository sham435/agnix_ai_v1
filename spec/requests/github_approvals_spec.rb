# frozen_string_literal: true

# Security contracts exercise multiple invariants in each scenario.
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength
require "rails_helper"

RSpec.describe "GitHub write confirmations", type: :request do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:integration) { create(:tool_integration, organization: organization, provider: "github", credentials: { api_key: "ghp_secret" }) }
  let(:endpoint) { "https://api.github.com/repos/acme/widgets/issues" }
  let(:approval_url) do
    Integrations::Github::CreateIssue.call(integration: integration,
      arguments: { "owner" => "acme", "repo" => "widgets", "title" => "Exact <script>title</script>", "body" => "Reviewed body" },
      context: { user: user, user_id: user.id, agent_id: agent.id, conversation_id: conversation.id }).fetch(:approval_url)
  end
  let(:token) { Rack::Utils.parse_query(URI.parse(approval_url).query).fetch("token") }

  it "requires authentication to inspect or confirm" do
    get approval_url
    expect(response).to redirect_to(login_path)
    post github_approval_path, params: { token: token }
    expect(response).to redirect_to(login_path)
    assert_not_requested(:post, endpoint)
  end

  it "renders exact escaped arguments and a POST form; ignores client argument changes" do
    api_login(user)
    get approval_url
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Reviewed body", "&lt;script&gt;", 'method="post"')
    expect(response.headers["Cache-Control"]).to include("no-store")
    assert_not_requested(:post, endpoint)
    stub = stub_request(:post, endpoint).with(body: {
      title: "Exact <script>title</script>", body: "Reviewed body"
    }).to_return(status: 201, body: { number: 42 }.to_json)
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post github_approval_path, params: { token: token, user_id: create(:user).id, title: "Forged title", approved: true },
      headers: { "X-CSRF-Token" => api_headers["X-CSRF-Token"] }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Created issue #42")
    expect(stub).to have_been_requested.once
    post github_approval_path, params: { token: token }, headers: { "X-CSRF-Token" => api_headers["X-CSRF-Token"] }
    expect(response).to have_http_status(:unprocessable_entity)
  ensure
    ActionController::Base.allow_forgery_protection = old
  end

  it "rejects a different authenticated user" do
    value = token
    api_login(create(:user))
    get github_approval_path(token: value)
    expect(response).to have_http_status(:not_found)
    post github_approval_path, params: { token: value, user_id: user.id, approved: true }
    expect(response).to have_http_status(:unprocessable_entity)
    assert_not_requested(:post, endpoint)
  end

  it "requires real CSRF protection on confirmation" do
    api_login(user)
    value = token
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post github_approval_path, params: { token: value, approved: true }
    expect(response).to have_http_status(:unprocessable_entity)
    assert_not_requested(:post, endpoint)
  ensure
    ActionController::Base.allow_forgery_protection = old
  end
end
