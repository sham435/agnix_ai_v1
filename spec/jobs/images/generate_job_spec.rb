# frozen_string_literal: true

# Phase 3e — Images::GenerateJob. The generator is stubbed at its public edge
# (real HTTP lives in generator_spec); everything else is the genuine stack:
# Solid-queue perform_now, real Assets::Ingest -> real Asset + Active Storage
# bytes, real Turbo::StreamsChannel broadcasts (spied), real DB transitions.
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable, RSpec/MultipleMemoizedHelpers

require "rails_helper"

RSpec.describe Images::GenerateJob, type: :job do
  # Genuine 1x1 PNG bytes (decodes to a real \x89PNG signature so the strict
  # Validator accepts it exactly like a provider response would).
  let(:png_b64) do
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  end
  let(:user) { create(:user) }
  let(:generation) { create(:image_generation, user: user) }
  let(:provider_image) do
    Images::Generator::Image.new(b64_json: png_b64, revised_prompt: "A refined lake", provider_id: "img_42")
  end
  let(:result) do
    Images::Generator::Result.new(images: [ provider_image ], created: 1_730_000_000, model: "gpt-image-1")
  end

  # Record broadcasts instead of relying on rspec-mocks keyword/hash
  # distinction (broadcast_*_to takes trailing kwargs).
  let(:gallery_broadcasts) { [] }
  let(:chat_broadcasts) { [] }

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |stream, **kwargs|
      gallery_broadcasts << [ stream, kwargs ]
    end
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) do |streamable, **kwargs|
      chat_broadcasts << [ streamable, kwargs ]
    end
  end

  def gallery_card_updates(generation)
    gallery_broadcasts.select do |stream, kwargs|
      stream == ImageGeneration.gallery_stream_name(generation.user) &&
        kwargs[:target] == "image-generation-#{generation.id}" &&
        kwargs[:html].is_a?(String)
    end
  end

  def chat_appends_for(conversation)
    chat_broadcasts.select do |streamable, kwargs|
      streamable == conversation &&
        kwargs[:target] == "messages-list" &&
        kwargs[:html].is_a?(String)
    end
  end

  def stub_generator(result: nil, error: nil)
    instance = instance_double(Images::Generator)
    if error
      allow(instance).to receive(:generate).and_raise(error)
    else
      allow(instance).to receive(:generate).and_return(result)
    end
    allow(Images::Generator).to receive(:new).and_return(instance)
    instance
  end

  describe "success path" do
    it "builds a ready image Asset through the ingest pipeline, links it, and broadcasts to the gallery" do
      stub_generator(result: result)

      described_class.perform_now(generation.id)
      generation.reload

      expect(generation.status).to eq("succeeded")
      asset = generation.asset
      expect(asset).to be_present
      expect(asset.status).to eq("ready")
      expect(asset.image?).to be(true)
      expect(asset.content_type).to eq("image/png")
      expect(asset.filename).to end_with(".png")
      expect(asset.byte_size).to be > 0
      expect(asset.file.attached?).to be(true)
      expect(asset.checksum).to eq(Digest::SHA256.hexdigest(asset.file.download))

      # Library reuse semantics come free with the pipeline.
      expect(LibraryItem.exists?(user: user, asset: asset)).to be(true)

      # Provider detail persisted for the record (never raw bytes).
      expect(generation.metadata["revised_prompt"]).to eq("A refined lake")
      expect(generation.metadata["provider_id"]).to eq("img_42")
      expect(generation.metadata["provider_model"]).to eq("gpt-image-1")

      # The gallery card for this exact row was refreshed over Turbo Streams.
      expect(gallery_card_updates(generation).size).to eq(2) # running skeleton + final card
    end

    it "broadcasts an image card into the chat for conversation-originated generations" do
      conversation = create(:conversation, user: user)
      generation = create(:image_generation, user: user,
                                             metadata: { "conversation_id" => conversation.id })
      stub_generator(result: result)

      described_class.perform_now(generation.id)

      expect(chat_appends_for(conversation).size).to eq(1)
      expect(chat_appends_for(conversation).first.last[:html]).to include("mountain lake")
    end

    it "keeps private gallery cards on distinct owner-only streams" do
      other = create(:user)
      theirs = create(:image_generation, user: other, prompt: "Another user's private prompt")
      stub_generator(result: result)

      described_class.perform_now(generation.id)
      described_class.perform_now(theirs.id)

      expect(gallery_card_updates(generation).map(&:first).uniq).to eq([ ImageGeneration.gallery_stream_name(user) ])
      expect(gallery_card_updates(theirs).map(&:first).uniq).to eq([ ImageGeneration.gallery_stream_name(other) ])
      expect(gallery_card_updates(generation).map { |_stream, kwargs| kwargs[:html] }.join).not_to include(theirs.prompt)
      expect(gallery_card_updates(theirs).map { |_stream, kwargs| kwargs[:html] }.join).not_to include(generation.prompt)
    end

    it "does not broadcast into a foreign conversation referenced by legacy metadata" do
      foreign = create(:conversation, user: create(:user))
      generation.update_column(:metadata, { "conversation_id" => foreign.id }.to_json)
      stub_generator(result: result)

      described_class.perform_now(generation.id)

      expect(chat_broadcasts).to be_empty
      expect(generation.reload).to be_succeeded
      expect(gallery_card_updates(generation).size).to eq(2)
    end

    it "is inert for rows already terminal or missing" do
      generator = stub_generator(result: result)
      generation.update!(status: "succeeded")

      described_class.perform_now(generation.id)

      expect(generator).not_to have_received(:generate)
      expect { described_class.perform_now("not-a-uuid") }.not_to raise_error
    end

    it "reuses the existing asset when identical bytes were generated before (dedupe)" do
      stub_generator(result: result)
      described_class.perform_now(generation.id)
      first_asset = generation.reload.asset

      other = create(:image_generation, user: user)
      described_class.perform_now(other.id)

      expect(other.reload.asset_id).to eq(first_asset.id)
    end
  end

  describe "failure path" do
    it "marks the row failed with the readable provider message and broadcasts the failed card" do
      stub_generator(error: Images::Generator::Error.new("The image provider is unavailable (HTTP 503). Try again later."))

      described_class.perform_now(generation.id)
      generation.reload

      expect(generation.status).to eq("failed")
      expect(generation.error).to include('unavailable (HTTP 503)')
      expect(generation.asset_id).to be_nil
      expect(gallery_card_updates(generation).last.last[:html]).to include("HTTP 503")
    end

    it "never re-raises provider errors into the queue (no silent retry spend)" do
      stub_generator(error: Images::Generator::Error.new("Image generation timed out waiting for the provider. Try again."))

      expect { described_class.perform_now(generation.id) }.not_to raise_error
      expect(generation.reload.status).to eq("failed")
    end

    it "records unexpected failures with a safe generic message" do
      stub_generator(error: RuntimeError.new("socket exploded internally"))

      described_class.perform_now(generation.id)

      expect(generation.reload.error).to eq("Image generation failed unexpectedly. Please try again.")
    end

    it "fails cleanly when the provider hands back undecodable image data" do
      bad_image = Images::Generator::Image.new(b64_json: "!!!not-base64!!!", revised_prompt: nil, provider_id: nil)
      bad_result = Images::Generator::Result.new(images: [ bad_image ], created: nil, model: "gpt-image-1")
      stub_generator(result: bad_result)

      described_class.perform_now(generation.id)

      expect(generation.reload.status).to eq("failed")
    end

    it "broadcasts a failure note into chat too" do
      conversation = create(:conversation, user: user)
      generation = create(:image_generation, user: user,
                                             metadata: { "conversation_id" => conversation.id })
      stub_generator(error: Images::Generator::Error.new("rate limited"))

      described_class.perform_now(generation.id)

      expect(chat_appends_for(conversation).size).to eq(1)
      expect(chat_appends_for(conversation).first.last[:html]).to include("rate limited")
    end

    it "does not broadcast a failure into another user's chat" do
      foreign = create(:conversation, user: create(:user))
      generation = create(:image_generation, user: user,
                                             metadata: { "conversation_id" => foreign.id })
      stub_generator(error: Images::Generator::Error.new("provider unavailable"))

      described_class.perform_now(generation.id)

      expect(chat_broadcasts).to be_empty
      expect(generation.reload).to be_failed
    end
  end

  describe "delivery and storage safety" do
    it "does not run or broadcast a fresh running row" do
      generator = stub_generator(result: result)
      generation.update!(status: "running")
      described_class.perform_now(generation.id)
      expect(generator).not_to have_received(:generate)
      expect(gallery_broadcasts).to be_empty
      expect(generation.reload).to be_running
    end

    it "ignores a duplicate delivery during the provider call" do
      generator = stub_generator(result: result)
      allow(generator).to receive(:generate) do
        described_class.perform_now(generation.id)
        result
      end
      described_class.perform_now(generation.id)
      expect(generator).to have_received(:generate).once
      expect(generation.reload).to be_succeeded
      expect(gallery_card_updates(generation).size).to eq(2)
    end

    it "fails a stale running row without repeating the provider request" do
      generator = stub_generator(result: result)
      generation.update!(status: "running")
      generation.update_columns(updated_at: ImageGeneration::RUNNING_LEASE.ago - 1.second)

      described_class.perform_now(generation.id)

      expect(generator).not_to have_received(:generate)
      expect(generation.reload).to be_failed
      expect(generation.error).to include("provider may have charged", "retry only deliberately")
      expect(generation.metadata["recovered_stale_at"]).to be_present
      expect(generation.retry_available?).to be(true)
      expect(gallery_card_updates(generation).size).to eq(1)
      expect(gallery_card_updates(generation).first.last[:html]).to include("provider may have charged")
    end

    it "persists cooldown metadata and preserves conversation linkage" do
      generation.update!(metadata: { "origin" => "chat" })
      stub_generator(error: Images::Generator::RateLimited.new(retry_after: "120"))
      described_class.perform_now(generation.id)
      expect(generation.reload).to be_failed
      expect(generation.metadata).to include("origin" => "chat", "retry_after" => "120")
      expect(generation.metadata["retry_at"]).to be_present
      expect(generation.error).to include("Retry manually after")
    end

    it "rejects base64-encoded non-images and truncated PNG signatures" do
      [ "arbitrary text", "\x89PNG\r\n\x1a\n".b ].each do |bytes|
        other = create(:image_generation, user: user)
        image = Images::Generator::Image.new(b64_json: Base64.strict_encode64(bytes), revised_prompt: nil, provider_id: nil)
        stub_generator(result: Images::Generator::Result.new(images: [ image ], created: nil, model: "gpt-image-1"))
        described_class.perform_now(other.id)
        expect(other.reload).to be_failed
        expect(other.asset_id).to be_nil
      end
    end

    it "rejects a deduped asset with no attached file" do
      asset = create(:asset, user: user, checksum: Digest::SHA256.hexdigest(Base64.strict_decode64(png_b64)))
      stub_generator(result: result)
      described_class.perform_now(generation.id)
      expect(generation.reload).to be_failed
      expect(generation.error).to eq("The generated image could not be stored.")
      expect(generation.asset_id).to be_nil
      expect(asset.file).not_to be_attached
    end
  end

  describe "queue contract" do
    include ActiveJob::TestHelper

    around do |example|
      previous = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = previous
    end

    it "runs on the dedicated images queue" do
      expect(described_class.new.queue_name).to eq("images")
    end

    it "enqueues by row id" do
      assert_enqueued_with(job: described_class, args: [ generation.id ]) do
        described_class.perform_later(generation.id)
      end
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable, RSpec/MultipleMemoizedHelpers
