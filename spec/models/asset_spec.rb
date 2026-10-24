# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Asset do
  describe "validations" do
    it { expect(build(:asset)).to be_valid }
    it { expect(build(:asset, filename: nil)).not_to be_valid }
    it { expect(build(:asset, byte_size: 0)).not_to be_valid }
    it { expect(build(:asset, status: "nonsense")).not_to be_valid }
    it { expect(build(:asset, checksum: nil)).not_to be_valid }

    it "rejects a duplicate checksum for the same user (dup-upload resolves to same asset)" do
      asset = create(:asset)
      expect(build(:asset, user: asset.user, checksum: asset.checksum)).not_to be_valid
      # same bytes for a different user are a distinct asset
      expect(build(:asset, checksum: asset.checksum)).to be_valid
    end
  end

  describe "associations" do
    it "deletes joins/library items cleanly and cascades from user" do
      user = create(:user)
      asset = create(:asset, user: user)
      message = create(:message, conversation: create(:conversation, agent: create(:agent), user: user))
      create(:message_attachment, message: message, asset: asset)
      create(:library_item, user: user, asset: asset)

      asset.destroy!
      expect(asset.message_attachments.count).to eq(0)
    end

    it "purges the stored blob on destroy" do
      asset = nil
      Tempfile.create("spec-upload-") do |f|
        f.write("blob bytes")
        f.rewind
        asset = build(:asset)
        asset.file.attach(io: f, filename: "n.txt", content_type: "text/plain")
        asset.save!
      end
      blob_key = asset.file.blob.key
      asset.destroy!
      expect(ActiveStorage::Blob.find_by(key: blob_key)).to be_nil
    end
  end

  describe "#readable_by?" do
    it "allows the owner and the owning project's user only" do
      owner = create(:user)
      other = create(:user)
      project_owner = create(:user)
      project = create(:project, user: project_owner, agent: create(:agent))
      asset = create(:asset, user: owner, project: project)

      expect(asset.readable_by?(owner)).to be true
      expect(asset.readable_by?(project_owner)).to be true
      expect(asset.readable_by?(other)).to be false
      expect(asset.readable_by?(nil)).to be false
    end
  end
end
