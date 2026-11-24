# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

RSpec.describe "WhatsApp webhook security", type: :request do
  let(:app_secret) { "whatsapp-app-secret" }
  let(:verify_token) { "whatsapp-verify-token" }
  let(:organization) { create(:organization) }
  let(:other_organization) { create(:organization) }
  let(:user) { create(:user, whatsapp_phone: "14155552671") }
  let(:other_user) { create(:user, whatsapp_phone: "14155559999") }
  let!(:other_agent) { create(:agent, organization: other_organization) }
  let!(:agent) { create(:agent, organization: organization) }
  let!(:integration) do
    create(:tool_integration, organization: organization, provider: "whatsapp",
      config: { "phone_number_id" => "phone-number-a" })
  end

  before do
    create(:membership, user: user, organization: organization)
    create(:membership, user: other_user, organization: other_organization)
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :app_secret).and_return(app_secret)
    allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :verify_token).and_return(verify_token)
    allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :auto_provision).and_return(false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WHATSAPP_APP_SECRET").and_return(nil)
    allow(ENV).to receive(:[]).with("WHATSAPP_VERIFY_TOKEN").and_return(nil)
    allow(AgentStreamJob).to receive(:perform_later)
  end

  def webhook_payload(phone_number_id: "phone-number-a", phone_number: user.whatsapp_phone,
    content: "Hello from WhatsApp")
    {
      "entry" => [ {
        "id" => "waba-1",
        "changes" => [ {
          "field" => "messages",
          "value" => {
            "messaging_product" => "whatsapp",
            "metadata" => { "phone_number_id" => phone_number_id },
            "contacts" => [ { "wa_id" => phone_number, "profile" => { "name" => "WhatsApp User" } } ],
            "messages" => [ {
              "id" => "wamid.1",
              "from" => phone_number,
              "timestamp" => "1700000000",
              "type" => "text",
              "text" => { "body" => content }
            } ]
          }
        } ]
      } ]
    }
  end

  def signature_for(body, secret = app_secret)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
  end

  def post_webhook(body, signature: signature_for(body))
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["X-Hub-Signature-256"] = signature if signature
    post "/webhooks/whatsapp", params: body, headers: headers
  end

  describe "GET verification" do
    it "returns the challenge for the configured verify token" do
      get "/webhooks/whatsapp", params: {
        "hub.mode" => "subscribe", "hub.verify_token" => verify_token, "hub.challenge" => "challenge-123"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("challenge-123")
    end

    it "rejects a wrong verify token" do
      get "/webhooks/whatsapp", params: {
        "hub.mode" => "subscribe", "hub.verify_token" => "wrong", "hub.challenge" => "challenge-123"
      }

      expect(response).to have_http_status(:forbidden)
    end

    it "fails closed when no verify token is configured" do
      allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :verify_token).and_return(nil)

      get "/webhooks/whatsapp", params: {
        "hub.mode" => "subscribe", "hub.verify_token" => "", "hub.challenge" => "challenge-123"
      }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST signature validation" do
    it "rejects a missing signature without creating records or queueing work" do
      body = webhook_payload.to_json

      expect { post_webhook(body, signature: nil) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:forbidden)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "rejects an invalid signature without creating records or queueing work" do
      body = webhook_payload.to_json

      expect { post_webhook(body, signature: "sha256=#{'0' * 64}") }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:forbidden)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "rejects a signature after the signed body is changed" do
      signed_body = webhook_payload(content: "original").to_json
      tampered_body = webhook_payload(content: "tampered").to_json

      post_webhook(tampered_body, signature: signature_for(signed_body))

      expect(response).to have_http_status(:forbidden)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "rejects the legacy SHA-1 header format" do
      post_webhook(webhook_payload.to_json, signature: "sha1=#{'0' * 40}")

      expect(response).to have_http_status(:forbidden)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "fails closed when no app secret is configured" do
      allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :app_secret).and_return(nil)

      post_webhook(webhook_payload.to_json)

      expect(response).to have_http_status(:forbidden)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end
  end

  describe "signed event tenant routing" do
    it "processes a valid event through the matching organization's agent" do
      post_webhook(webhook_payload.to_json)

      expect(response).to have_http_status(:ok)
      expect(Conversation.count).to eq(1)
      expect(response.parsed_body).to eq("received" => true)
      conversation = Conversation.find_by!(user: user, agent: agent)
      expect(conversation.agent).not_to eq(other_agent)
      expect(conversation.messages.last.content).to eq("Hello from WhatsApp")
      expect(AgentStreamJob).to have_received(:perform_later).with(hash_including(
        conversation_id: conversation.id,
        user_id: user.id,
        message_content: "Hello from WhatsApp",
        channel: :whatsapp,
        phone_number: user.whatsapp_phone,
        whatsapp_integration_id: integration.id
      ))
    end

    it "reuses the user's existing conversation with that organization's agent" do
      create(:conversation, user: user, agent: agent)

      expect { post_webhook(webhook_payload.to_json) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(Conversation.find_by!(user: user, agent: agent).messages.last.content).to eq("Hello from WhatsApp")
      expect(AgentStreamJob).to have_received(:perform_later).once
    end

    it "ignores a valid event for an unknown phone number id" do
      body = webhook_payload(phone_number_id: "unknown").to_json

      expect { post_webhook(body) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "ignores a valid event for a paused integration" do
      integration.update!(is_active: false)

      expect { post_webhook(webhook_payload.to_json) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "fails closed when two organizations claim the same phone number id" do
      create(:tool_integration, organization: other_organization, provider: "whatsapp",
        config: { "phone_number_id" => "phone-number-a" })

      expect { post_webhook(webhook_payload.to_json) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "does not route another organization's user into this tenant" do
      allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :auto_provision).and_return(true)
      body = webhook_payload(phone_number: other_user.whatsapp_phone).to_json
      membership_count = Membership.count

      expect { post_webhook(body) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(Membership.count).to eq(membership_count)
      expect(other_user.organizations).not_to include(organization)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "does not fall back to another organization's active agent" do
      agent.update!(is_active: false)

      expect { post_webhook(webhook_payload.to_json) }.not_to change(Conversation, :count)

      expect(response).to have_http_status(:ok)
      expect(AgentStreamJob).not_to have_received(:perform_later)
    end

    it "auto-provisions a new user only inside the matching organization" do
      allow(Rails.application.credentials).to receive(:dig).with(:whatsapp, :auto_provision).and_return(true)
      phone_number = "14155550000"

      expect { post_webhook(webhook_payload(phone_number: phone_number).to_json) }.to change(User, :count).by(1)

      expect(response).to have_http_status(:ok)
      created_user = User.find_by!(whatsapp_phone: phone_number)
      expect(created_user.organizations).to contain_exactly(organization)
      expect(Conversation.find_by!(user: created_user).agent).to eq(agent)
      expect(AgentStreamJob).to have_received(:perform_later).once
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
