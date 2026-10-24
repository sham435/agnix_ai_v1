# frozen_string_literal: true

# Integration-style specs for the server-backed attachment drafts lifecycle.
# One narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "API v1 attachment drafts", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:token) { "bdd61119-6e1f-4b1a-a1d1-b2ae2a1b9a77" }

  before do
    api_login(user)
    allow(AgentStreamJob).to receive(:perform_later).and_return(true)
  end

  def make_asset(owner = user)
    create(:asset, user: owner, filename: "restored.md") do |asset|
      asset.file.attach(
        io: StringIO.new("draft fixture bytes"),
        filename: "restored.md",
        content_type: "text/markdown"
      )
    end
  end

  describe "POST /api/v1/attachment_drafts" do
    it "records a draft for the caller's asset and refreshes expiry on repeat" do
      asset = make_asset

      post "/api/v1/attachment_drafts", params: { draft_token: token, asset_id: asset.id, label: "my README" },
                                        headers: api_headers
      expect(response).to have_http_status(:created)
      draft_id = JSON.parse(response.body)["draft"]["id"]
      expect(draft_id).to be_present

      # Repeat for the same (user, token, asset): refreshed row, not duplicated.
      post "/api/v1/attachment_drafts", params: { draft_token: token, asset_id: asset.id }, headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["draft"]["id"]).to eq(draft_id)
      expect(AttachmentDraft.count).to eq(1)
    end

    it "never drafts another user's asset" do
      foreign_asset = make_asset(other_user)

      expect do
        post "/api/v1/attachment_drafts", params: { draft_token: token, asset_id: foreign_asset.id }, headers: api_headers
      end.not_to change(AttachmentDraft, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "rejects a blank token" do
      asset = make_asset
      post "/api/v1/attachment_drafts", params: { asset_id: asset.id }, headers: api_headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /api/v1/attachment_drafts" do
    it "restores live drafts for the token and scope-cleans expired ones" do
      asset = make_asset
      stale = make_asset
      foreign = make_asset(other_user)

      AttachmentDraft.create!(user: user, draft_token: token, asset: asset, label: "restored.md", expires_at: 1.hour.from_now)
      AttachmentDraft.create!(user: user, draft_token: token, asset: stale, label: "old.md", expires_at: 2.minutes.ago)
      # Another user's row with the SAME token must never leak through.
      foreign_draft = AttachmentDraft.create!(user: other_user, draft_token: token, asset: foreign, expires_at: 1.hour.from_now)

      get "/api/v1/attachment_drafts", params: { draft_token: token }, headers: api_headers
      expect(response).to have_http_status(:ok)
      drafts = JSON.parse(response.body)["drafts"]

      expect(drafts.length).to eq(1)
      expect(drafts.first["asset_id"]).to eq(asset.id)
      expect(drafts.first["label"]).to eq("restored.md")
      # Lifecycle cleanup only touches THIS user's expired rows; other users'
      # live rows survive, and no leaked draft exists.
      expect(AttachmentDraft.expired.where(user_id: user.id).exists?).to be false
      expect(AttachmentDraft.exists?(foreign_draft.id)).to be true
      expect(AttachmentDraft.count).to eq(2)
    end

    it "requires the token parameter" do
      get "/api/v1/attachment_drafts", headers: api_headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /api/v1/attachment_drafts/:id" do
    it "removes only a matching-token draft of the same user" do
      asset = make_asset
      draft = AttachmentDraft.create!(user: user, draft_token: token, asset: asset, expires_at: 1.hour.from_now)

      delete "/api/v1/attachment_drafts/#{draft.id}?draft_token=#{token}", headers: api_headers
      expect(response).to have_http_status(:no_content)
      expect(AttachmentDraft.exists?(draft.id)).to be false
    end

    it "leaves other tokens' rows when the token does not match" do
      asset = make_asset
      draft = AttachmentDraft.create!(user: user, draft_token: token, asset: asset, expires_at: 1.hour.from_now)

      delete "/api/v1/attachment_drafts/#{draft.id}?draft_token=wrong-token", headers: api_headers
      expect(response).to have_http_status(:no_content)
      expect(AttachmentDraft.exists?(draft.id)).to be true
    end
  end

  describe "message-create consume (full composer flow)" do
    let(:conversation) { create(:conversation, user: user) }

    it "consumes only attached drafts inside the successful send; failures keep them" do
      attached_asset = make_asset
      removed_asset = make_asset
      # Simulate the composer row whose chip removal DELETE failed: extraction
      # failed, asset NOT attached to the message, draft still on the server.
      failed_asset = make_asset
      create(:asset_extraction, asset: failed_asset, status: "failed", error_code: "no_text_found")

      attached_draft = AttachmentDraft.record!(user: user, draft_token: token, asset: attached_asset, label: "keep.md")
      AttachmentDraft.record!(user: user, draft_token: token, asset: removed_asset, label: "removed.md")
      not_attached = AttachmentDraft.record!(user: user, draft_token: token, asset: failed_asset, label: "photo.png")

      post "/api/v1/conversations/#{conversation.id}/messages",
           params: { content: "", attachment_asset_ids: [ attached_asset.id ], attachment_draft_token: token },
           headers: api_headers
      expect(response).to have_http_status(:created)

      # Attached draft consumed; removed draft gone; not-attached draft kept.
      expect(AttachmentDraft.exists?(attached_draft.id)).to be false
      expect(AttachmentDraft.exists?(not_attached.id)).to be true

      # Failed sends never eat drafts: only the bad CONTENT state rolls back.
      post "/api/v1/attachment_drafts", params: { draft_token: token, asset_id: not_attached.asset_id }, headers: api_headers
      post "/api/v1/conversations/#{conversation.id}/messages",
           params: { content: "", attachment_draft_token: token }, headers: api_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttachmentDraft.exists?(not_attached.id)).to be true

      # A rerun with the same token + asset attaches the message this time.
      post "/api/v1/conversations/#{conversation.id}/messages",
           params: { content: "", attachment_asset_ids: [ failed_asset.id ], attachment_draft_token: token },
           headers: api_headers
      expect(JSON.parse(response.body)["message"]["content"]).to be_blank
      expect(AttachmentDraft.exists?(not_attached.id)).to be false
    end
  end
end
