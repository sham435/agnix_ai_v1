# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "attachment-aware message flow", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:agent) { create(:agent) }
  let(:conversation) { create(:conversation, user: user, agent: agent) }

  before do
    # The streaming job performs real agent LLM calls — out of scope here.
    allow(AgentStreamJob).to receive(:perform_later).and_return(true)
  end

  def create_asset_for(user, checksum: SecureRandom.hex(32))
    create(:asset, user: user, checksum: checksum)
  end

  it "attaches permitted assets to a user message and ignores foreign assets" do
    api_login(user)
    own = create_asset_for(user)
    foreign = create_asset_for(other_user)

    post "/api/v1/conversations/#{conversation.id}/messages",
         params: { content: "Here are my files", attachment_asset_ids: [ own.id.to_s, foreign.id.to_s ] },
         headers: api_headers

    expect(response).to have_http_status(:created)
    message = Message.find(JSON.parse(response.body).dig("message", "id"))
    expect(message.assets).to contain_exactly(own)
  end

  it "old no-attachment message requests still work (regression)" do
    api_login(user)
    post "/api/v1/conversations/#{conversation.id}/messages", params: { content: "plain message, no files" }, headers: api_headers
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["message"]["content"]).to eq("plain message, no files")
  end

  it "web turbo path accepts attachment ids too" do
    api_login(user) # sets session cookie storage
    own = create_asset_for(user)

    # ApiLoginHelper performs an API session create; for the web controller the
    # session cookie persists across requests in the same rack session.
    post conversation_messages_path(conversation),
         params: { message: { content: "web attach", attachment_asset_ids: [ own.id.to_s ] } },
         headers: api_headers

    expect(response.status).to be_in([ 200, 201 ])
    expect(conversation.messages.where(content: "web attach").first.assets).to contain_exactly(own)
  end

  # The reported production failure: user attaches a file, types nothing,
  # hits send. Used to 422 on the blank-content validation — a file-only send
  # is a legitimate message.
  it "accepts a file-only send with blank content (web turbo path)" do
    api_login(user)
    own = create_asset_for(user, checksum: SecureRandom.hex(32))

    post conversation_messages_path(conversation),
         params: { message: { content: "", attachment_asset_ids: [ own.id.to_s ] } },
         headers: api_headers

    expect(response.status).to be_in([ 200, 201, 302 ])
    message = conversation.messages.order(:created_at).last
    expect(message.assets).to contain_exactly(own)
    expect(message.content).to be_blank
  end

  it "accepts a file-only send with blank content (api path)" do
    api_login(user)
    own = create_asset_for(user, checksum: SecureRandom.hex(32))

    post "/api/v1/conversations/#{conversation.id}/messages",
         params: { content: "", attachment_asset_ids: [ own.id.to_s ] },
         headers: api_headers

    expect(response).to have_http_status(:created)
    message = conversation.messages.order(:created_at).last
    expect(message.assets).to contain_exactly(own)
  end

  it "still rejects a genuinely empty text-only message (no attachments)" do
    api_login(user)
    post conversation_messages_path(conversation),
         params: { message: { content: "" } },
         headers: api_headers

    expect(response.status).to be_in([ 422, 400 ])
  end
end
