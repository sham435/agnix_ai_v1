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

  def gallery_card_updates(generation_id)
    gallery_broadcasts.select do |stream, kwargs|
      stream == "image_generations" &&
        kwargs[:target] == "image-generation-#{generation_id}" &&
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
      expect(gallery_card_updates(generation.id).size).to eq(2) # running skeleton + final card
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
      expect(gallery_card_updates(generation.id).last.last[:html]).to include("HTTP 503")
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
