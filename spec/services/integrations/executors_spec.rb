# frozen_string_literal: true

# Phase 4d — Plugin executors against WebMock-ed providers. Each example
# proves the call is REAL HTTP with the organization's own encrypted
# credentials (never the global app config), maps provider answers into the
# bounded { ok: ... } contract, and refuses cleanly on missing inputs.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/NamedSubject, RSpec/DescribeClass

require "rails_helper"

RSpec.describe "Integration plugin executors", type: :service do
  let(:organization) { create(:organization) }

  def integration_for(provider, credentials: {}, config: {}, org: organization)
    create(:tool_integration, organization: org, provider: provider,
                              name: provider.titleize, credentials: credentials, config: config)
  end

  def json_body(status: 200, body: {}, headers: {})
    { status: status, body: body.to_json,
      headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  describe Integrations::Slack::PostMessage do
    let(:integration) { integration_for("slack", credentials: { "api_key" => "xoxb-abc" }) }

    it "posts with the bot token and returns the message ts" do
      stub = stub_request(:post, described_class::ENDPOINT)
        .with(headers: { "Authorization" => "Bearer xoxb-abc" },
              body: { channel: "#general", text: "ship it" })
        .to_return(json_body(body: { ok: true, channel: "C123", ts: "171.222" }))

      result = described_class.call(integration: integration, arguments: { "channel" => "#general", "text" => "ship it" })

      expect(result).to include(ok: true, provider: "slack", message_id: "171.222", channel: "C123")
      expect(stub).to have_been_requested
    end

    it "surfaces Slack's in-body business error" do
      stub_request(:post, described_class::ENDPOINT)
        .to_return(json_body(body: { ok: false, error: "not_in_channel" }))

      result = described_class.call(integration: integration, arguments: { "channel" => "#x", "text" => "hi" })
      expect(result).to include(ok: false, error_code: "provider_error", provider_error: "not_in_channel")
    end

    it "refuses without credentials or required arguments" do
      blank = integration_for("slack", credentials: {}, org: create(:organization))
      expect(described_class.call(integration: blank, arguments: { "channel" => "#x", "text" => "hi" })[:error_code])
        .to eq("missing_credentials")

      result = described_class.call(integration: integration, arguments: { "channel" => "", "text" => "hi" })
      expect(result[:error_code]).to eq("invalid_request")
      assert_not_requested(:post, described_class::ENDPOINT)
    end
  end

  describe Integrations::Resend::SendEmail do
    let(:integration) do
      integration_for("resend", credentials: { "api_key" => "re_key", "from_address" => "bot@shams.ai" })
    end

    it "sends with the stored default sender" do
      stub = stub_request(:post, described_class::ENDPOINT)
        .with { |req| JSON.parse(req.body)["from"] == "bot@shams.ai" }
        .to_return(json_body(body: { "id" => "email-1" }))

      result = described_class.call(integration: integration,
                                    arguments: { "to" => "a@b.co", "subject" => "Hi", "body" => "Yo" })

      expect(result).to include(ok: true, provider: "resend", email_id: "email-1")
      expect(stub).to have_been_requested
    end

    it "refuses when no sender can be resolved" do
      no_from = integration_for("resend", credentials: { "api_key" => "re_key" })
      result = described_class.call(integration: no_from,
                                    arguments: { "to" => "a@b.co", "subject" => "Hi", "body" => "Yo" })
      expect(result[:error_code]).to eq("missing_sender")
    end

    it "reports provider failures without leaking the key" do
      stub_request(:post, described_class::ENDPOINT)
        .to_return(json_body(status: 422, body: { "message" => "valid domain required" }))

      result = described_class.call(integration: integration,
                                    arguments: { "to" => "a@b.co", "subject" => "Hi", "body" => "Yo" })
      expect(result).to include(ok: false, error_code: "provider_error")
      expect(result.to_json).not_to include("re_key")
    end
  end

  describe Integrations::Postmark::SendEmail do
    let(:integration) do
      integration_for("postmark", credentials: { "api_key" => "pm-token", "from_address" => "bot@shams.ai" })
    end

    it "delivers through the org's server token" do
      stub = stub_request(:post, "https://api.postmarkapp.com/email")
        .with(headers: { "X-Postmark-Server-Token" => "pm-token" })
        .to_return(json_body(body: { "MessageID" => "pm-1", "To" => "a@b.co", "ErrorCode" => 0 }))

      result = described_class.call(integration: integration,
                                    arguments: { "to" => "a@b.co", "subject" => "Hi", "body" => "Yo" })

      expect(result[:ok]).to be(true)
      expect(result[:email_id]).to eq("pm-1")
      expect(stub).to have_been_requested
    end

    it "refuses on missing token" do
      blank = integration_for("postmark", credentials: {})
      expect(described_class.call(integration: blank,
                                  arguments: { "to" => "a@b.co", "subject" => "Hi", "body" => "Yo" })[:error_code])
        .to eq("missing_credentials")
    end
  end

  describe Integrations::Stripe::ListRecentPayments do
    let(:integration) { integration_for("stripe", credentials: { "api_key" => "sk_org_key" }) }

    it "lists charges with the per-request key, never the global config" do
      stub = stub_request(:get, "https://api.stripe.com/v1/charges")
        .with(headers: { "Authorization" => "Bearer sk_org_key" }, query: { limit: "3" })
        .to_return(json_body(body: {
                               "object" => "list",
                               "data" => [ { "id" => "ch_1", "object" => "charge", "amount" => 2500,
                                             "currency" => "usd", "status" => "succeeded",
                                             "created" => 1_700_000_000 } ]
                             }))

      result = described_class.call(integration: integration, arguments: { "limit" => 3 })

      expect(result[:ok]).to be(true)
      payment = result[:payments].first
      expect(payment).to include(id: "ch_1", amount: 2500, status: "succeeded")
      expect(payment[:created]).to start_with("2023-11-14")
      expect(stub).to have_been_requested
    end

    it "caps absurd limits and reports Stripe errors bounded" do
      stub_request(:get, "https://api.stripe.com/v1/charges")
        .with(query: { limit: "50" })
        .to_return(json_body(status: 401, body: { "error" => { "message" => "Invalid API Key provided" } }))

      result = described_class.call(integration: integration, arguments: { "limit" => 9_999 })
      expect(result[:ok]).to be(false)
      expect(result.to_json).not_to include("sk_org_key")
    end
  end

  describe Integrations::Stripe::CreatePaymentLink do
    let(:integration) { integration_for("stripe", credentials: { "api_key" => "sk_org_key" }) }
    let(:valid_args) do
      { "amount_cents" => 2500, "description" => "Consult", "success_url" => "https://shams.ai/thanks" }
    end

    it "creates a checkout session and returns the sendable link" do
      stub = stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
        .with do |req|
          payload = CGI.parse(req.body)
          payload["line_items[0][price_data][unit_amount]"] == [ "2500" ] &&
            payload["mode"] == [ "payment" ]
        end
        .to_return(json_body(body: { "id" => "cs_test_9", "url" => "https://checkout.stripe.com/c/cs_test_9" }))

      result = described_class.call(integration: integration, arguments: valid_args)

      expect(result).to include(ok: true, session_id: "cs_test_9", amount: 2500)
      expect(result[:checkout_url]).to eq("https://checkout.stripe.com/c/cs_test_9")
      expect(stub).to have_been_requested
    end

    it "rejects malformed amounts, currencies, and success urls before any request" do
      result = described_class.call(integration: integration,
                                    arguments: { "amount_cents" => 0, "currency" => "usdx",
                                                 "description" => "", "success_url" => "nope" })
      expect(result[:error_code]).to eq("invalid_request")
      expect(result[:errors].length).to eq(4)
      assert_not_requested(:post, "https://api.stripe.com/v1/checkout/sessions")
    end
  end

  describe Integrations::Github::CreateIssue do
    let(:integration) { integration_for("github", credentials: { "api_key" => "ghp_tok" }) }

    it "opens an issue with the PAT and version headers" do
      stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/issues")
        .with(
          headers: {
            "Authorization" => "Bearer ghp_tok",
            "Accept" => "application/vnd.github+json",
            "X-GitHub-Api-Version" => "2022-11-28"
          },
          body: hash_including("title" => "Flaky spec")
        )
        .to_return(json_body(status: 201, body: { "number" => 12, "html_url" => "https://github.com/acme/widgets/issues/12", "title" => "Flaky spec" }))

      result = described_class.call(integration: integration,
                                    arguments: { "owner" => "acme", "repo" => "widgets", "title" => "Flaky spec", "labels" => [ "bug" ] })

      expect(result).to include(ok: true, issue_number: 12)
      expect(stub).to have_been_requested
    end

    it "refuses without owner/repo/title" do
      result = described_class.call(integration: integration, arguments: {})
      expect(result[:error_code]).to eq("invalid_request")
      expect(result[:errors].length).to eq(3)
    end

    it "reports GitHub's message on failure" do
      stub_request(:post, %r{api\.github\.com/repos})
        .to_return(json_body(status: 404, body: { "message" => "Not Found" }))

      result = described_class.call(integration: integration,
                                    arguments: { "owner" => "acme", "repo" => "ghost", "title" => "x" })
      expect(result).to include(ok: false, error_code: "provider_error", provider_error: "Not Found")
    end
  end

  describe Integrations::Github::ListIssues do
    let(:integration) { integration_for("github", credentials: { "api_key" => "ghp_tok" }) }

    it "lists newest issues and maps the fields agents need" do
      stub_request(:get, "https://api.github.com/repos/acme/widgets/issues")
        .with(query: { state: "open", per_page: "2", sort: "created", direction: "desc" })
        .to_return(json_body(body: [
                             { "number" => 3, "title" => "B", "state" => "open",
                               "html_url" => "u3", "updated_at" => "2026-01-02T00:00:00Z" },
                             { "number" => 2, "title" => "A", "state" => "open",
                               "html_url" => "u2", "updated_at" => "2026-01-01T00:00:00Z" },
                             { "number" => 1, "title" => "old", "state" => "open",
                               "html_url" => "u1", "updated_at" => "2025-12-31T00:00:00Z" }
                           ]))

      result = described_class.call(integration: integration,
                                    arguments: { "owner" => "acme", "repo" => "widgets", "limit" => 2 })

      expect(result[:ok]).to be(true)
      expect(result[:issues].map { |i| i[:number] }).to eq([ 3, 2 ])
    end

    it "rejects unknown states" do
      result = described_class.call(integration: integration,
                                    arguments: { "owner" => "acme", "repo" => "w", "state" => "banana" })
      expect(result[:error_code]).to eq("invalid_request")
    end
  end

  describe Integrations::Whatsapp::SendMessage do
    let(:integration) do
      integration_for("whatsapp", credentials: { "api_key" => "wa-token" },
                      config: { "phone_number_id" => "9911" })
    end

    it "sends a text through the Cloud API number" do
      stub = stub_request(:post, "https://graph.facebook.com/v20.0/9911/messages")
        .with(
          headers: { "Authorization" => "Bearer wa-token" },
          body: hash_including("to" => "14155552671", "type" => "text")
        )
        .to_return(json_body(body: { "messages" => [ { "id" => "wamid.X" } ] }))

      result = described_class.call(integration: integration,
                                    arguments: { "to" => "+1 (415) 555-2671", "text" => "ping" })

      expect(result).to include(ok: true, provider: "whatsapp", message_id: "wamid.X")
      expect(stub).to have_been_requested
    end

    it "refuses without the phone number id config" do
      bare = integration_for("whatsapp", credentials: { "api_key" => "wa-token" })
      result = described_class.call(integration: bare, arguments: { "to" => "1415", "text" => "x" })
      expect(result[:error_code]).to eq("missing_phone_number_id")
    end
  end

  describe Integrations::Notion::Search do
    let(:integration) { integration_for("notion", credentials: { "api_key" => "secret_n" }) }

    it "searches with the integration version header and extracts titles" do
      stub = stub_request(:post, described_class::ENDPOINT)
        .with(
          headers: { "Notion-Version" => "2022-06-28", "Authorization" => "Bearer secret_n" },
          body: hash_including("query" => "roadmap")
        )
        .to_return(json_body(body: {
                               "results" => [ {
                                 "id" => "p1", "object" => "page",
                                 "properties" => {
                                   "title" => { "type" => "title",
                                                "title" => [ { "plain_text" => "Road" }, { "plain_text" => "map" } ] }
                                 }
                               } ]
                             }))

      result = described_class.call(integration: integration, arguments: { "query" => "roadmap" })

      expect(result[:ok]).to be(true)
      expect(result[:results].first).to include(id: "p1", object: "page", title: "Roadmap")
      expect(stub).to have_been_requested
    end

    it "omits an empty query and reports provider errors" do
      stub_request(:post, described_class::ENDPOINT)
        .with { |req| !req.body.to_s.include?("query") }
        .to_return(json_body(status: 404, body: { "message" => "API token isn't shared" }))

      result = described_class.call(integration: integration, arguments: {})
      expect(result).to include(ok: false, error_code: "provider_error")
    end
  end

  describe Integrations::Webhook::PostJson do
    let(:integration) do
      integration_for("webhook", config: { "webhook_url" => "https://hooks.example.test/agent" })
    end

    it "posts the payload and echoes a bounded response without the URL" do
      stub = stub_request(:post, "https://hooks.example.test/agent")
        .with(
          headers: { "Content-Type" => "application/json", "User-Agent" => "ShamsAI-Plugins" },
          body: { "kind" => "build", "event" => "done" }
        )
        .to_return(status: 202, body: "queued", headers: {})

      result = described_class.call(integration: integration,
                                    arguments: { "payload" => { "kind" => "build" }, "event" => "done" })

      expect(result).to include(ok: true, status: 202, response: "queued")
      expect(result.to_json).not_to include("hooks.example.test")
      expect(stub).to have_been_requested
    end

    it "refuses missing or non-http endpoints and non-object payloads" do
      bare = integration_for("webhook", org: create(:organization))
      expect(described_class.call(integration: bare, arguments: { "payload" => {} })[:error_code])
        .to eq("missing_endpoint")

      bad = integration_for("webhook", config: { "webhook_url" => "not a url" }, org: create(:organization))
      expect(described_class.call(integration: bad, arguments: { "payload" => {} })[:error_code])
        .to eq("invalid_endpoint")

      result = described_class.call(integration: integration, arguments: { "payload" => "text" })
      expect(result[:error_code]).to eq("invalid_request")
    end
  end
end
