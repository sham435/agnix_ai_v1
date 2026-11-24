# frozen_string_literal: true

# Phase 3e — ImageGeneration model contract. One row per generation request;
# status drives both the gallery skeleton and the in-chat "one job per
# conversation" gate, so the enum + jsonb metadata semantics are load-bearing.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe ImageGeneration, type: :model do
  let(:user) { create(:user) }

  it "ships with honest catalog defaults straight from the schema" do
    generation = create(:image_generation, user: user)

    expect(generation.status).to eq("queued")
    expect(generation.provider).to eq("openai")
    expect(generation.model).to eq("gpt-image-1")
    expect(generation.size).to eq("1024x1024")
    expect(generation.quality).to eq("auto")
    expect(generation.n).to eq(1)
    expect(generation.metadata).to eq({})
    expect(generation.asset_id).to be_nil
    expect(generation.organization_id).to be_nil
  end

  describe "validations" do
    def build_invalid(attrs)
      build(:image_generation, user: user, **attrs)
    end

    it "requires a prompt" do
      expect(build_invalid(prompt: "")).not_to be_valid
      expect(build_invalid(prompt: "  ")).not_to be_valid
    end

    it "only accepts the catalogued provider, model, size and quality" do
      expect(build_invalid(provider: "stability")).not_to be_valid
      expect(build_invalid(model: "dall-e-2")).not_to be_valid
      expect(build_invalid(size: "512x512")).not_to be_valid
      expect(build_invalid(quality: "ultra")).not_to be_valid

      expect(build_invalid(size: "1024x1536")).to be_valid
      expect(build_invalid(size: "auto")).to be_valid
      expect(build_invalid(quality: "high")).to be_valid
    end

    it "bounds n between 1 and 4" do
      expect(build_invalid(n: 0)).not_to be_valid
      expect(build_invalid(n: 5)).not_to be_valid
      expect(build_invalid(n: 4)).to be_valid
    end
  end

  describe "status enum" do
    it "exposes predicates for every state" do
      generation = build(:image_generation, user: user)
      expect(generation).to be_queued

      %w[running succeeded failed].each do |state|
        generation.status = state
        expect(generation.public_send("#{state}?")).to be(true)
      end
    end

    it "refuses states outside the enum" do
      expect { build(:image_generation, user: user).status = "cancelled" }
        .to raise_error(ArgumentError)
    end
  end

  describe "in-flight conversation gate" do
    let(:conversation) { create(:conversation, user: user) }

    it "is true while a queued or running row references the conversation" do
      create(:image_generation, user: user, metadata: { "conversation_id" => conversation.id })
      expect(described_class.in_flight_for_conversation?(conversation.id)).to be(true)

      running = create(:image_generation, :running, user: user)
      running.merge_metadata!("conversation_id" => conversation.id)
      expect(described_class.in_flight_for_conversation?(conversation.id)).to be(true)
    end

    it "is false once rows reach a terminal state" do
      create(:image_generation, :succeeded, user: user,
                                             metadata: { "conversation_id" => conversation.id })
      create(:image_generation, :failed, user: user,
                                          metadata: { "conversation_id" => conversation.id })
      expect(described_class.in_flight_for_conversation?(conversation.id)).to be(false)
    end

    it "is scoped per conversation and tolerant of blanks" do
      other = create(:conversation, user: user)
      create(:image_generation, user: user, metadata: { "conversation_id" => conversation.id })

      expect(described_class.in_flight_for_conversation?(other.id)).to be(false)
      expect(described_class.in_flight_for_conversation?(nil)).to be(false)
      expect(described_class.for_conversation(conversation.id).count).to eq(1)
    end
  end

  describe "gallery stream identity" do
    it "uses a stable, distinct stream for each owner" do
      other = create(:user)

      expect(described_class.gallery_stream_name(user)).to eq(described_class.gallery_stream_name(user.reload))
      expect(described_class.gallery_stream_name(user)).not_to eq(described_class.gallery_stream_name(other))
    end
  end

  describe "stale running recovery" do
    it "leaves a fresh running lease untouched" do
      generation = create(:image_generation, :running, user: user)

      expect(generation.recover_stale_running!).to be(false)
      expect(generation.reload).to be_running
      expect(generation.error).to be_nil
    end

    it "fails an expired lease with a billing warning and allows deliberate retry" do
      conversation = create(:conversation, user: user)
      generation = create(:image_generation, :running, user: user,
                                                       metadata: { "conversation_id" => conversation.id })
      generation.update_columns(updated_at: described_class::RUNNING_LEASE.ago - 1.second)

      expect(generation.recover_stale_running!).to be(true)
      generation.reload
      expect(generation).to be_failed
      expect(generation.error).to include("provider may have charged", "retry only deliberately")
      expect(generation.metadata).to include("conversation_id" => conversation.id, "recovered_stale_at" => anything)
      expect(generation.retry_available?).to be(true)
      expect(generation.asset_id).to be_nil
    end

    it "recovers an expired lease only once under the row lock" do
      generation = create(:image_generation, :running, user: user)
      generation.update_columns(updated_at: described_class::RUNNING_LEASE.ago - 1.second)
      duplicate = described_class.find(generation.id)

      expect(generation.recover_stale_running!).to be(true)
      expect(duplicate.recover_stale_running!).to be(false)
      expect(duplicate.reload).to be_failed
    end
  end

  describe "queued claim" do
    it "reloads stale deliveries under lock and claims only once" do
      generation = create(:image_generation, user: user)
      stale = described_class.find(generation.id)
      expect(generation.claim!).to be(true)
      expect(stale.claim!).to be(false)
      expect(stale).to be_running
    end

    it "does not claim running or terminal rows" do
      %w[running succeeded failed].each do |status|
        generation = create(:image_generation, user: user, status: status)
        expect(generation.claim!).to be(false)
        expect(generation.reload.status).to eq(status)
      end
    end
  end

  describe "metadata + failure helpers" do
    it "merges provider detail without clobbering earlier keys and drops nils" do
      generation = create(:image_generation, user: user,
                                               metadata: { "conversation_id" => "conv-1" })
      generation.merge_metadata!("revised_prompt" => "Refined", provider_id: nil)

      expect(generation.reload.metadata).to eq("conversation_id" => "conv-1", "revised_prompt" => "Refined")
    end

    it "marks failure with a truncated readable message" do
      generation = create(:image_generation, user: user)
      generation.mark_failed!("x" * 1_500)

      generation.reload
      expect(generation.status).to eq("failed")
      expect(generation.error.length).to eq(1000)
    end

    it "parses raw JSON metadata and treats malformed or non-object JSON as empty" do
      generation = build(:image_generation, user: user)
      generation.metadata = { "conversation_id" => "conv-1" }.to_json
      expect(generation.normalized_metadata).to eq("conversation_id" => "conv-1")

      [ "{malformed", "[]", "null" ].each do |raw|
        generation.metadata = raw
        expect(generation.normalized_metadata).to eq({})
      end
    end

    it "merges provider detail into raw JSON metadata" do
      generation = create(:image_generation, user: user, metadata: { "conversation_id" => "conv-1" }.to_json)
      generation.metadata = { "conversation_id" => "conv-1" }.to_json
      generation.merge_metadata!("revised_prompt" => "Refined", provider_id: nil)

      expect(generation.reload.metadata).to eq("conversation_id" => "conv-1", "revised_prompt" => "Refined")
    end

    it "applies the retry cooldown from raw JSON metadata" do
      generation = create(:image_generation, :failed, user: user)
      generation.metadata = { "retry_at" => 2.minutes.from_now.iso8601 }.to_json
      expect(generation.retry_available?).to be(false)

      travel 3.minutes do
        expect(generation.retry_available?).to be(true)
      end
    end

    it "preserves raw JSON conversation linkage when marking failure" do
      generation = create(:image_generation, user: user)
      generation.metadata = { "conversation_id" => "conv-1" }.to_json
      retry_at = 2.minutes.from_now.iso8601
      generation.mark_failed!("Provider failed", metadata: { "retry_at" => retry_at, "provider_id" => nil })

      generation.reload
      expect(generation).to be_failed
      expect(generation.metadata).to eq("conversation_id" => "conv-1", "retry_at" => retry_at)
    end
  end

  describe "owner recent count (sidebar badge)" do
    it "counts only succeeded generations from the last week" do
      fresh = create(:image_generation, :succeeded, user: user)
      create(:image_generation, :succeeded, user: user)
      create(:image_generation, :failed, user: user)
      old = create(:image_generation, :succeeded, user: user)
      old.update_columns(created_at: 8.days.ago)

      other_user = create(:user)
      create(:image_generation, :succeeded, user: other_user)

      expect(user.reload.recent_image_generation_count).to eq(2)
      expect(user.reload.recent_image_generation_count).to be_a(Integer)
      expect(fresh.succeeded?).to be(true)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
