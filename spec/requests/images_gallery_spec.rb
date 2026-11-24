# frozen_string_literal: true

# Phase 3e — ImagesController HTTP contract. Proves authentication, strict
# current_user scoping, the turbo_stream optimistic card + JSON create paths,
# scoped destroy/regenerate, and — the security-critical one — that download
# answers 404 for anyone but the owner (Asset#readable_by? is the gate).
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require "rails_helper"

RSpec.describe "Images gallery", type: :request do
  let(:user) { create(:user) }
  let(:other) { create(:user) }

  before do
    allow(Images::GenerateJob).to receive(:perform_later)
  end

  def sign_in_as(actor = user)
    api_login(actor)
  end

  def form_headers
    { "X-CSRF-Token" => api_headers["X-CSRF-Token"],
      "ACCEPT" => "text/vnd.turbo-stream.html, text/html" }
  end

  describe "authentication" do
    it "redirects an anonymous visitor to login" do
      get images_path
      expect(response).to have_http_status(:redirect)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET /images" do
    it "renders only the current user's generations" do
      sign_in_as
      mine = create(:image_generation, :succeeded, user: user, prompt: "Aurora over a fjord")
      theirs = create(:image_generation, user: other, prompt: "Secret private prompt")

      get images_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Aurora over a fjord")
      expect(response.body).not_to include("Secret private prompt")
      expect(response.body).to include("image-generation-#{mine.id}")
      expect(response.body).not_to include("image-generation-#{theirs.id}")
    end

    it "subscribes each user only to their own gallery stream" do
      owner_stream = Turbo::StreamsChannel.signed_stream_name(ImageGeneration.gallery_stream_name(user))
      other_stream = Turbo::StreamsChannel.signed_stream_name(ImageGeneration.gallery_stream_name(other))

      sign_in_as
      get images_path
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("turbo-cable-stream-source")["signed-stream-name"]).to eq(owner_stream)
      expect(page.at_css("turbo-cable-stream-source")["signed-stream-name"]).not_to eq(other_stream)

      sign_in_as(other)
      get images_path
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("turbo-cable-stream-source")["signed-stream-name"]).to eq(other_stream)
      expect(page.at_css("turbo-cable-stream-source")["signed-stream-name"]).not_to eq(owner_stream)
    end

    it "returns to the originating conversation and carries context into the form" do
      conversation = create(:conversation, user: user)
      sign_in_as
      get images_path(conversation_id: conversation.id)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('a[aria-label="Back to chat"]')["href"]).to eq(conversation_path(conversation))
      expect(page.at_css('input[name="conversation_id"]')["value"]).to eq(conversation.id)
      expect(response.body).to include("Return to conversation", "min-h-[44px]")
    end

    it "preserves an originating route but rejects external return destinations" do
      conversation = create(:conversation, user: user)
      sign_in_as
      route = conversation_path(conversation, view: "chat")
      get images_path(conversation_id: conversation.id, return_to: route)
      expect(Nokogiri::HTML(response.body).at_css('a[aria-label="Back to chat"]')["href"]).to eq(route)
      get images_path(conversation_id: conversation.id, return_to: "//external.example#{conversation_path(conversation)}")
      expect(Nokogiri::HTML(response.body).at_css('a[aria-label="Back to chat"]')["href"]).to eq(conversation_path(conversation))
    end

    it "uses a recent owned conversation for direct navigation, never a foreign origin" do
      conversation = create(:conversation, user: user)
      foreign = create(:conversation, user: other)
      sign_in_as
      get images_path(conversation_id: foreign.id)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('a[aria-label="Back to chat"]')["href"]).to eq(conversation_path(conversation))
      expect(page.at_css('input[name="conversation_id"]')["value"]).to be_blank
    end

    it "returns to the chats landing screen when no conversation exists" do
      sign_in_as
      get images_path
      expect(Nokogiri::HTML(response.body).at_css('a[aria-label="Back to chat"]')["href"]).to eq(conversations_path)
    end

    it "paginates at most 24 rows per page" do
      sign_in_as
      create_list(:image_generation, 25, user: user)

      get images_path
      expect(response.body.scan(/id="image-generation-/).size).to eq(24)

      get images_path(page: 2)
      expect(response.body.scan(/id="image-generation-/).size).to eq(1)
    end
  end

  describe "POST /images" do
    it "queues a generation and answers with an optimistic turbo-stream card" do
      sign_in_as

      post images_path,
           params: { image_generation: { prompt: "Neon koi pond", size: "1536x1024", quality: "high" } },
           headers: form_headers

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      generation = ImageGeneration.succeeded.or(ImageGeneration.queued).last
      expect(generation.prompt).to eq("Neon koi pond")
      expect(generation.status).to eq("queued")
      expect(generation.user_id).to eq(user.id)
      expect(response.body).to include("image-generation-#{generation.id}")
      expect(Images::GenerateJob).to have_received(:perform_later).with(generation.id)
    end

    it "associates a queued task with its owned originating conversation" do
      conversation = create(:conversation, user: user)
      sign_in_as
      post images_path, params: { conversation_id: conversation.id, image_generation: { prompt: "Context image" } }, headers: api_headers
      expect(ImageGeneration.sole.metadata["conversation_id"]).to eq(conversation.id)
      get images_path(conversation_id: conversation.id)
      get conversation_path(conversation)
      expect(ImageGeneration.sole).to be_queued
      expect(Images::GenerateJob).to have_received(:perform_later).once
    end

    it "does not associate another user's conversation" do
      foreign = create(:conversation, user: other)
      sign_in_as
      post images_path, params: { conversation_id: foreign.id, image_generation: { prompt: "Private context" } }, headers: api_headers
      expect(ImageGeneration.sole.metadata["conversation_id"]).to be_nil
    end

    it "answers JSON with 202 + payload for API clients" do
      sign_in_as

      post images_path, params: { image_generation: { prompt: "Brutalist lighthouse" } },
           headers: api_headers

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body["prompt"]).to eq("Brutalist lighthouse")
      expect(body["status"]).to eq("queued")
      expect(ImageGeneration.find(body["id"]).user_id).to eq(user.id)
    end

    it "rejects an empty prompt with a readable turbo-stream error" do
      sign_in_as

      post images_path, params: { image_generation: { prompt: "" } }, headers: form_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Prompt can&#39;t be blank")
      expect(ImageGeneration.count).to eq(0)
    end
  end

  describe "DELETE /images/:id" do
    it "removes the row and streams the card away" do
      sign_in_as
      generation = create(:image_generation, user: user)

      delete image_path(generation), headers: form_headers

      expect(response.body).to include("<turbo-stream action=\"remove\" target=\"image-generation-#{generation.id}\">")
      expect(ImageGeneration.find_by(id: generation.id)).to be_nil
    end

    it "cannot remove someone else's generation" do
      sign_in_as
      theirs = create(:image_generation, user: other)

      delete image_path(theirs), headers: form_headers

      expect(ImageGeneration.exists?(theirs.id)).to be(true)
    end
  end

  describe "POST /images/:id/regenerate" do
    it "clones the request as a NEW queued row" do
      sign_in_as
      original = create(:image_generation, :succeeded, user: user, prompt: "Same idea, better light")

      post regenerate_image_path(original), headers: form_headers

      clone = ImageGeneration.where.not(id: original.id).order(:created_at).last
      expect(clone.prompt).to eq(original.prompt)
      expect(clone.model).to eq(original.model)
      expect(clone.status).to eq("queued")
      expect(Images::GenerateJob).to have_received(:perform_later).with(clone.id)
    end

    it "does not resubmit an active task or bypass the provider cooldown" do
      sign_in_as
      active = create(:image_generation, user: user)
      limited = create(:image_generation, :failed, user: user,
        metadata: { "retry_at" => (Time.current + 2.minutes).iso8601 }, error: "Wait before retrying")
      [ active, limited ].each do |generation|
        post regenerate_image_path(generation), headers: form_headers
        expect(response).to have_http_status(:see_other)
      end
      expect(ImageGeneration.count).to eq(2)
      expect(Images::GenerateJob).not_to have_received(:perform_later)
      travel 3.minutes do
        post regenerate_image_path(limited), headers: form_headers
        expect(ImageGeneration.count).to eq(3)
        expect(ImageGeneration.order(:created_at).last.metadata["retry_at"]).to be_nil
      end
    end

    it "allows deliberate regeneration after stale worker recovery" do
      original = create(:image_generation, :running, user: user)
      original.update_columns(updated_at: ImageGeneration::RUNNING_LEASE.ago - 1.second)
      original.recover_stale_running!
      sign_in_as

      post regenerate_image_path(original), headers: form_headers

      clone = ImageGeneration.where.not(id: original.id).sole
      expect(clone).to be_queued
      expect(original.reload).to be_failed
      expect(Images::GenerateJob).to have_received(:perform_later).with(clone.id)
    end

    it "preserves the conversation on a deliberate retry after failure" do
      conversation = create(:conversation, user: user)
      original = create(:image_generation, :failed, user: user, metadata: { "conversation_id" => conversation.id })
      sign_in_as
      post regenerate_image_path(original), headers: form_headers
      clone = ImageGeneration.where.not(id: original.id).sole
      expect(clone.metadata["conversation_id"]).to eq(conversation.id)
      expect(original.reload).to be_failed
    end

    it "regenerates raw JSON-string metadata and preserves conversation context" do
      conversation = create(:conversation, user: user)
      original = create(:image_generation, :failed, user: user)
      original.update_column(:metadata, {
        "conversation_id" => conversation.id,
        "conversation_path" => conversation_path(conversation),
        "revised_prompt" => "Old refined prompt",
        "provider_id" => "provider-image"
      }.to_json)
      sign_in_as

      post regenerate_image_path(original), headers: api_headers.merge("ACCEPT" => "text/html")

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(images_path(
        conversation_id: conversation.id, return_to: conversation_path(conversation)
      ))
      clone = ImageGeneration.where.not(id: original.id).sole
      expect(clone.metadata).to eq(
        "conversation_id" => conversation.id, "conversation_path" => conversation_path(conversation)
      )
      expect(Images::GenerateJob).to have_received(:perform_later).with(clone.id)
    end

    it "is scoped to the owner" do
      sign_in_as
      theirs = create(:image_generation, user: other)

      post regenerate_image_path(theirs), headers: form_headers

      expect(response).to have_http_status(:redirect)
      expect(ImageGeneration.where(user: other).count).to eq(1)
    end
  end

  describe "GET /images/:id/download" do
    it "serves the owner's bytes inline" do
      sign_in_as
      generation = create(:image_generation, :succeeded, user: user)

      get download_image_path(generation)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Content-Disposition"].to_s).to include("inline")
      expect(response.body).to eq("fake-png-bytes")
    end

    it "404s for another user's generation (never leaks existence)" do
      sign_in_as
      theirs = create(:image_generation, :succeeded, user: other)

      get download_image_path(theirs)

      expect(response).to have_http_status(:not_found)
    end

    it "404s while no asset exists yet" do
      sign_in_as
      queued = create(:image_generation, user: user)

      get download_image_path(queued)

      expect(response).to have_http_status(:not_found)
    end

    it "sends anonymous visitors to the login wall instead of bytes" do
      generation = create(:image_generation, :succeeded, user: user)
      get download_image_path(generation)
      expect(response).to have_http_status(:redirect) # auth wall before scoping
    end
  end

  describe "GET /images/:id (modal frame)" do
    it "renders the enlarge view inside the modal turbo frame for the owner" do
      sign_in_as
      generation = create(:image_generation, :succeeded, user: user, prompt: "Macro frostflower")

      get image_path(generation), headers: { "ACCEPT" => "text/html" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("turbo-frame id=\"modal\"")
      expect(response.body).to include("Macro frostflower")
    end

    it "redirects the frame target out for another user" do
      sign_in_as
      theirs = create(:image_generation, user: other)

      get image_path(theirs)

      expect(response).to have_http_status(:redirect)
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
