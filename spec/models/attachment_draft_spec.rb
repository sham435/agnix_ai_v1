# frozen_string_literal: true

# Unit-level behavior of the server-backed attachment drafts (lifecycle,
# uniqueness, bounded growth). Narrative examples on purpose: the full HTTP
# flow lives in spec/requests/api/v1/attachment_drafts_spec.rb.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe AttachmentDraft do
  let(:user) { create(:user) }
  let(:asset) do
    create(:asset, user: user) do |record|
      record.file.attach(io: StringIO.new("x"), filename: "model.md", content_type: "text/markdown")
    end
  end

  it "validates the token and scopes uniqueness to user+token+asset" do
    described_class.create!(user: user, draft_token: "t-1", asset: asset, expires_at: 1.hour.from_now,
                            label: "model.md")

    duplicate = described_class.new(user: user, draft_token: "t-1", asset: asset, expires_at: 1.hour.from_now)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:draft_token]).to be_present

    other_asset = create(:asset, user: user)
    same_token_other_asset = described_class.new(user: user, draft_token: "t-1", asset: other_asset,
                                                 expires_at: 1.hour.from_now)
    expect(same_token_other_asset).to be_valid
  end

  it "records refreshes expiry and label rather than duplicating rows" do
    first = described_class.record!(user: user, draft_token: "t-2", asset: asset, label: "renamed.md")
    refreshed = described_class.record!(user: user, draft_token: "t-2", asset: asset, label: "renamed.md")

    expect(refreshed.id).to eq(first.id)
    expect(described_class.count).to eq(1)
    expect(first.reload.expires_at).to be >= described_class::DEFAULT_TTL.from_now - 1.minute
  end

  it "keeps the table bounded by dropping the user's oldest drafts over the cap" do
    over_cap = Array.new(described_class::MAX_USER_DRAFTS + 2) do |n|
      { draft_token: "cap-token-#{n}", asset: create(:asset, user: user) }
    end

    over_cap.each { |args| described_class.record!(user: user, **args) }

    expect(described_class.where(user: user).count).to be <= described_class::MAX_USER_DRAFTS
  end

  it "consume_attached_for ignores blank tokens and empty ids" do
    described_class.create!(user: user, draft_token: "t-3", asset: asset, expires_at: 1.hour.from_now)

    described_class.consume_attached_for(user, "", [])
    described_class.consume_attached_for(user, nil, nil)
    expect(described_class.count).to eq(1)
  end
end
