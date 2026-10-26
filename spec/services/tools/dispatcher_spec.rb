# frozen_string_literal: true

# Phase 4d — Dispatcher contract: bounded refusals for unknown tools, invalid
# arguments, and missing connections; org-scoped integration resolution (a
# forged id can never reach another org's row); touch_usage only on a
# completed call; executor blowups normalized into bounded error hashes.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Tools::Dispatcher, type: :service do
  let(:organization) { create(:organization) }
  let(:integration) do
    create(:tool_integration, organization: organization, provider: "slack",
                             credentials: { "api_key" => "xoxb-test-123" })
  end
  let(:arguments) { { "channel" => "#general", "text" => "hello" } }

  def stub_slack(status: 200, body: {})
    stub_request(:post, Integrations::Slack::PostMessage::ENDPOINT)
      .to_return(status: status, body: body.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "refusals before execution" do
    it "refuses names the catalog does not own" do
      result = described_class.call("slack.fly", arguments: arguments, organization: organization)
      expect(result).to include(ok: false, error_code: "unknown_tool")
      assert_not_requested(:post, Integrations::Slack::PostMessage::ENDPOINT)
    end

    it "refuses non-dotted names too (registry tools are not dispatched here)" do
      result = described_class.call("calculator", arguments: arguments, organization: organization)
      expect(result[:error_code]).to eq("unknown_tool")
    end

    it "rejects arguments that fail the tool's JSON schema before touching providers" do
      result = described_class.call("slack.post_message", arguments: { "channel" => "#a" }, organization: organization)
      expect(result[:ok]).to be(false)
      expect(result[:error_code]).to eq("invalid_request")
      expect(result[:errors]).to be_an(Array)
    end

    it "refuses when the organization has no connected row" do
      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)
      expect(result).to include(ok: false, error_code: "not_connected", plugin: "slack")
    end

    it "refuses when the only row is paused" do
      integration.update!(is_active: false)
      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)
      expect(result[:error_code]).to eq("not_connected")
    end

    it "refuses a nil organization outright" do
      result = described_class.call("slack.post_message", arguments: arguments, organization: nil)
      expect(result[:error_code]).to eq("not_connected")
    end
  end

  describe "integration resolution" do
    it "never executes another organization's integration for a forged id" do
      other_org = create(:organization)
      other_row = create(:tool_integration, organization: other_org, provider: "slack",
                                           credentials: { "api_key" => "xoxb-victim" })

      result = described_class.call("slack.post_message", arguments: arguments,
                                    organization: organization, integration_id: other_row.id)

      expect(result[:error_code]).to eq("not_connected")
      assert_not_requested(:post, Integrations::Slack::PostMessage::ENDPOINT)
    end

    it "uses the pinned integration when it belongs to the org" do
      row = integration
      stub = stub_request(:post, Integrations::Slack::PostMessage::ENDPOINT)
        .with(headers: { "Authorization" => "Bearer xoxb-test-123" })
        .to_return(status: 200, body: { ok: true, channel: "C1", ts: "1.1" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      result = described_class.call("slack.post_message", arguments: arguments,
                                    organization: organization, integration_id: row.id)

      expect(result[:ok]).to be(true)
      expect(stub).to have_been_requested
    end

    it "falls back to the org's active row when the pinned id no longer resolves" do
      integration # connected below
      stub_slack(body: { ok: true, channel: "C1", ts: "1.1" })
      result = described_class.call("slack.post_message", arguments: arguments,
                                    organization: organization,
                                    integration_id: "00000000-0000-0000-0000-000000000000")
      expect(result[:ok]).to be(true)
    end
  end

  describe "execution outcomes" do
    it "runs the real executor and stamps last_used_at on success" do
      row = integration
      stub_slack(body: { ok: true, channel: "C1", ts: "173.05" })

      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)

      expect(result).to include(ok: true, provider: "slack", message_id: "173.05")
      expect(row.reload.last_used_at).to be_within(2.seconds).of(Time.current)
    end

    it "does not touch usage when the provider rejects the call" do
      row = integration
      stub_slack(body: { ok: false, error: "channel_not_found" })

      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)

      expect(result).to include(ok: false, error_code: "provider_error")
      expect(result[:provider_error]).to eq("channel_not_found")
      expect(row.reload.last_used_at).to be_nil
    end

    it "normalizes executor results that are not ok-shaped hashes" do
      integration
      allow(Integrations::Slack::PostMessage).to receive(:call).and_return("junk")

      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)
      expect(result).to include(ok: false, error_code: "bad_executor_result")
    end

    it "converts executor exceptions into a bounded execution_failed refusal" do
      integration
      allow(Integrations::Slack::PostMessage).to receive(:call).and_raise(RuntimeError, "x" * 500)

      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)

      expect(result[:ok]).to be(false)
      expect(result[:error_code]).to eq("execution_failed")
      expect(result[:detail].length).to eq(200)
    end

    it "never leaks the credential into the refusal payload" do
      integration
      stub_slack(status: 500, body: {})

      result = described_class.call("slack.post_message", arguments: arguments, organization: organization)

      expect(result.to_json).not_to include("xoxb-test-123")
    end
  end
end
