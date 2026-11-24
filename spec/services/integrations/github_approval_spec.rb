# frozen_string_literal: true

# Security contracts exercise multiple invariants in each scenario.
# rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/SpecFilePathFormat
require "rails_helper"

RSpec.describe Integrations::Github::Approval do
  let(:organization) { create(:organization) }
  let(:user) { organization.owner }
  let(:agent) { create(:agent, organization: organization) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }
  let(:integration) { create(:tool_integration, organization: organization, provider: "github", credentials: { api_key: "ghp_secret" }) }
  let(:arguments) { { "owner" => " acme ", "repo" => "widgets", "title" => " Bug ", "body" => "Exact body", "labels" => [ "bug" ] } }
  let(:context) { { user: user, user_id: user.id, agent_id: agent.id, conversation_id: conversation.id } }
  let(:endpoint) { "https://api.github.com/repos/acme/widgets/issues" }

  def request_approval(args = arguments, ctx = context)
    Integrations::Github::CreateIssue.call(integration: integration, arguments: args, context: ctx)
  end

  def token
    Rack::Utils.parse_query(URI.parse(request_approval.fetch(:approval_url)).query).fetch("token")
  end

  def confirm(value, acting_user = user)
    described_class.call(action: :confirm, user: acting_user, token: value)
  end

  def audit
    conversation.messages.last.metadata.fetch(described_class::KEY).fetch("audit")
  end

  it "returns a bounded review link without writing, even with model approval flags" do
    result = request_approval(arguments, context.merge(approved: true, approval_token: "forged"))
    expect(result[:error_code]).to eq("approval_required")
    expect(result[:approval_url].bytesize).to be < 1000
    assert_not_requested(:post, endpoint)
  end

  it "rejects arbitrary boolean arguments" do
    expect(request_approval(arguments.merge("approved" => true))[:error_code]).to eq("invalid_request")
    assert_not_requested(:post, endpoint)
  end

  it "checks conversation owner, agent and organization" do
    stranger = create(:user)
    expect(request_approval(arguments, context.merge(user: stranger, user_id: stranger.id))[:error_code]).to eq("forbidden")
    expect(request_approval(arguments, context.merge(agent_id: create(:agent).id))[:error_code]).to eq("forbidden")
    expect(request_approval(arguments, context.merge(user_id: stranger.id))[:error_code]).to eq("forbidden")
    assert_not_requested(:post, endpoint)
  end

  it "rejects wrong users and revoked organization access at confirmation" do
    value = token
    expect(confirm(value, create(:user))[:error_code]).to eq("approval_unavailable")
    integration.update!(organization: create(:organization))
    expect(confirm(value)[:error_code]).to eq("approval_unavailable")
    assert_not_requested(:post, endpoint)
  end

  it "rejects expiration and forged tokens" do
    value = token
    expect(confirm("#{value}forged")[:error_code]).to eq("approval_unavailable")
    travel 11.minutes do
      expect(confirm(value)[:error_code]).to eq("approval_unavailable")
    end
    assert_not_requested(:post, endpoint)
  end

  it "detects stored argument tampering" do
    value = token
    row = conversation.messages.last
    metadata = row.metadata.deep_dup
    metadata[described_class::KEY]["binding"]["arguments"]["title"] = "Different issue"
    row.update!(metadata: metadata)
    expect(confirm(value)[:error_code]).to eq("approval_unavailable")
    assert_not_requested(:post, endpoint)
  end

  it "executes only the exact reviewed canonical arguments once and audits both sides" do
    value = token
    review = described_class.call(action: :inspect, user: user, token: value)
    expected = arguments.merge("owner" => "acme", "title" => "Bug")
    expect(review.dig(:binding, "arguments")).to eq(expected)
    stub = stub_request(:post, endpoint).with(
      headers: { "Authorization" => "Bearer ghp_secret", "X-GitHub-Api-Version" => "2022-11-28" },
      body: expected.except("owner", "repo")
    ).to_return(status: 201, body: { number: 12 }.to_json)
    expect(confirm(value)).to include(ok: true, issue_number: 12)
    expect(confirm(value)[:error_code]).to eq("approval_unavailable")
    expect(stub).to have_been_requested.once
    expect(audit.pluck("state")).to eq(%w[requested confirmed attempted succeeded])
    expect(audit.to_json).not_to include("ghp_secret", "Exact body")
  end

  it "durably consumes and sanitizes a failed provider write" do
    value = token
    stub = stub_request(:post, endpoint).to_raise(StandardError.new("ghp_secret sensitive"))
    expect(confirm(value)[:error_code]).to eq("request_failed")
    expect(audit.last).to include("state" => "failed", "error_code" => "request_failed")
    expect(audit.to_json).not_to include("ghp_secret", "sensitive")
    expect(confirm(value)[:error_code]).to eq("approval_unavailable")
    expect(stub).to have_been_requested.once
  end

  it "audits HTTP rejection without persisting provider response text" do
    value = token
    stub_request(:post, endpoint).to_return(status: 403, body: { message: "ghp_secret forbidden" }.to_json)
    expect(confirm(value)[:error_code]).to eq("provider_error")
    expect(audit.last).to include("state" => "failed", "error_code" => "provider_error")
    expect(audit.to_json).not_to include("ghp_secret", "forbidden")
  end

  it "refuses another confirmation while the first provider call is in flight" do
    value = token
    stub = stub_request(:post, endpoint).to_return do
      expect(audit.pluck("state")).to eq(%w[requested confirmed attempted])
      expect(confirm(value)[:error_code]).to eq("approval_unavailable")
      { status: 201, body: { number: 13 }.to_json }
    end
    expect(confirm(value)).to include(ok: true, issue_number: 13)
    expect(stub).to have_been_requested.once
  end

  it "fails closed if the pre-write audit cannot be persisted" do
    value = token
    row = conversation.messages.last
    allow(Message).to receive(:find).with(row.id).and_return(row)
    allow(row).to receive(:update_column).and_raise(ActiveRecord::StatementInvalid)
    expect { confirm(value) }.to raise_error(ActiveRecord::StatementInvalid)
    assert_not_requested(:post, endpoint)
  end
end
