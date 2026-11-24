# frozen_string_literal: true

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe "Channel session revocation", type: :channel do
  describe ConversationChannel, type: :channel do
    let(:user) { create(:user, email: "conversation-channel-owner@example.test") }
    let(:organization) { create(:organization, owner: user, slug: "conversation-channel-org") }
    let(:agent) { create(:agent, organization: organization, slug: "conversation-channel-agent") }
    let(:conversation) { create(:conversation, user: user, agent: agent) }
    let(:auth_session) { AuthSession.start(user) }

    before do
      close_options = nil
      stub_connection(current_user: user, current_auth_session_id: auth_session.id)
      connection.define_singleton_method(:close) { |reason:, reconnect:| close_options = { reason: reason, reconnect: reconnect } }
      connection.define_singleton_method(:close_options) { close_options }
      subscribe(conversation_id: conversation.id)
      allow(ActionCable.server).to receive(:broadcast)
    end

    it "admits a message while the device session remains active" do
      outcome = Conversations::TurnAdmission::Outcome.new(status: :started, request_id: "cable-request", queued_count: 0)
      allow(Conversations::TurnAdmission).to receive(:call).and_return(outcome)

      perform :speak, { "content" => "Hello" }

      expect(ActionCable.server).to have_received(:broadcast).with(
        "conversation:#{conversation.id}", hash_including(type: "message_admitted", request_id: "cable-request")
      )
    end

    it "closes without admitting a message after the device is revoked" do
      auth_session.update!(revoked_at: Time.current)
      allow(Conversations::TurnAdmission).to receive(:call)

      perform :speak, { "content" => "Must not run" }

      expect(Conversations::TurnAdmission).not_to have_received(:call)
      expect(connection.close_options).to eq(reason: "session_revoked", reconnect: false)
      expect(subscription.streams).to be_empty
      expect(conversation.messages).to be_empty
    end

    it "closes without cancelling a run after the device is revoked" do
      run = create(:run, :running, agent: agent, conversation: conversation)
      auth_session.update!(revoked_at: Time.current)
      allow(Conversations::TurnAdmission).to receive(:publish_tasks)

      perform :stop, {}

      expect(Conversations::TurnAdmission).not_to have_received(:publish_tasks)
      expect(run.reload.status).to eq("running")
      expect(connection.close_options).to eq(reason: "session_revoked", reconnect: false)
      expect(subscription.streams).to be_empty
    end
  end

  describe StreamingChannel, type: :channel do
    let(:user) { create(:user, email: "streaming-channel-owner@example.test") }
    let(:organization) { create(:organization, owner: user, slug: "streaming-channel-org") }
    let(:agent) { create(:agent, organization: organization, slug: "streaming-channel-agent") }
    let(:conversation) { create(:conversation, user: user, agent: agent) }
    let(:auth_session) { AuthSession.start(user) }

    before do
      close_options = nil
      stub_connection(current_user: user, current_auth_session_id: auth_session.id)
      connection.define_singleton_method(:close) { |reason:, reconnect:| close_options = { reason: reason, reconnect: reconnect } }
      connection.define_singleton_method(:close_options) { close_options }
      subscribe
    end

    it "does not honor stop or regenerate commands from a revoked device" do
      run = create(:run, :running, agent: agent, conversation: conversation)
      auth_session.update!(revoked_at: Time.current)
      allow(Conversations::RegenerateChat).to receive(:call)

      perform :receive, { "action" => "stop_generation", "conversation_id" => conversation.id }
      perform :receive, { "action" => "regenerate", "conversation_id" => conversation.id }

      expect(Conversations::RegenerateChat).not_to have_received(:call)
      expect(run.reload.status).to eq("running")
      expect(connection.close_options).to eq(reason: "session_revoked", reconnect: false)
      expect(subscription.streams).to be_empty
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
