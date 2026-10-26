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
