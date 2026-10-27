# frozen_string_literal: true

require "rails_helper"

RSpec.describe Message, type: :model do
  let(:conversation) { create(:conversation) }

  describe "content validation" do
    it "rejects a user message with blank content and no attachments" do
      msg = described_class.new(conversation: conversation, role: "user", content: "")
      expect(msg).not_to be_valid
      expect(msg.errors[:content]).to include("can't be blank")
    end

    it "accepts a user message with attachments and no text body" do
      asset = create(:asset, user: conversation.user)
      msg = described_class.new(conversation: conversation, role: "user", content: "")
      msg.pending_attachment_asset_ids = [ asset.id ]
      expect(msg).to be_valid
    end

    it "accepts an assistant message with tool_calls and no text body" do
      msg = described_class.new(
        conversation: conversation,
        role: "assistant",
        content: "",
        tool_calls: [ { "id" => "call_1", "type" => "function", "function" => { "name" => "calculator", "arguments" => "{}" } } ]
      )
      expect(msg).to be_valid
    end

    # The root-cause fix for the historical "lone dot in bubble" bug: the
    # streaming placeholder is now legitimately blank while the run is in
    # flight, because metadata["streaming"] unlocks a validation waiver.
    it "accepts an assistant streaming placeholder with blank content when metadata.streaming is true" do
      msg = described_class.new(
        conversation: conversation,
        role: "assistant",
        content: "",
        metadata: { "streaming" => true }
      )
      expect(msg).to be_valid
    end

    it "rejects an assistant message with blank content when metadata.streaming is absent" do
      msg = described_class.new(
        conversation: conversation,
        role: "assistant",
        content: "",
        metadata: {}
      )
      expect(msg).not_to be_valid
    end

    it "rejects an assistant message with blank content when metadata.streaming is false" do
      msg = described_class.new(
        conversation: conversation,
        role: "assistant",
        content: "",
        metadata: { "streaming" => false }
      )
      expect(msg).not_to be_valid
    end
  end

  describe "#streaming?" do
    it "returns true when metadata.streaming is true" do
      msg = described_class.new(metadata: { "streaming" => true })
      expect(msg.streaming?).to be true
    end

    it "returns false when metadata is empty" do
      msg = described_class.new(metadata: {})
      expect(msg.streaming?).to be false
    end

    it "returns false when metadata.streaming is missing" do
      msg = described_class.new(metadata: { "other" => true })
      expect(msg.streaming?).to be false
    end

    it "returns false when metadata.streaming is not true" do
      msg = described_class.new(metadata: { "streaming" => "yes" })
      expect(msg.streaming?).to be false
    end
  end

  describe "#empty_response?" do
    it "returns true when metadata.empty_response is true" do
      msg = described_class.new(metadata: { "empty_response" => true })
      expect(msg.empty_response?).to be true
    end

    it "returns false otherwise" do
      expect(described_class.new(metadata: {}).empty_response?).to be false
      expect(described_class.new(metadata: { "empty_response" => false }).empty_response?).to be false
    end
  end
end
