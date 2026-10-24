# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe "API v1 assets", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:open_uploads) { [] }

  after do
    open_uploads.each { |dir| FileUtils.remove_entry(dir) rescue nil }
  end

  # Rack::Test::UploadedFile takes its filename from the path basename — so we
  # stage a tmpfile at a directory whose child IS the target filename.
  def upload(name, type, content)
    dir = Dir.mktmpdir("shams-upload-")
    path = File.join(dir, name)
    File.binwrite(path, content)
    open_uploads << dir
    Rack::Test::UploadedFile.new(path, type)
  end

  before { api_login(user)
allow(AgentStreamJob).to receive(:perform_later).and_return(true)
   }


  describe "POST /api/v1/assets" do
    it "creates an asset with extraction states (inline job finishes completed)" do
      post "/api/v1/assets", params: { file: upload("notes.txt", "text/plain", "upload me text") },
                             headers: api_headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["asset"]["filename"]).to eq("notes.txt")
      expect(json["asset"]["category"]).to eq("text")
      expect(json["extraction"]["status"]).to eq("completed")
      expect(json["asset"]["id"]).to eq(user.assets.first.id)
    end

    it "rejects fake mime/images by magic bytes with a safe error code" do
      post "/api/v1/assets", params: { file: upload("img.png", "image/png", "text pretending to be an image") },
                             headers: api_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to eq({ "error" => "upload_rejected", "error_code" => "mime_mismatch" })
    end

    it "rejects executables" do
      post "/api/v1/assets", params: { file: upload("update.exe", "application/x-msdownload", "MZ\x00binary") },
                             headers: api_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error_code"]).to eq("executable_forbidden")
    end

    it "rejects oversized files (25 MiB cap)" do
      post "/api/v1/assets", params: { file: upload("big.txt", "text/plain", "x" * (25.megabytes + 1)) },
                             headers: api_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error_code"]).to eq("too_large")
    end

    it "requires authentication" do
      reset! # drop the signed-in session this example inherited

      get "/api/v1/csrf"
      token = JSON.parse(response.body)["token"]

      post "/api/v1/assets", params: { file: upload("x.txt", "text/plain", "hi") },
                             headers: { "X-CSRF-Token" => token, "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/library and add-to-library" do
    it "lists library items and reuses — no asset duplication" do
      asset = create(:asset, user: user, checksum: SecureRandom.hex(32))

      post "/api/v1/assets/#{asset.id}/add_to_library", headers: api_headers
      expect(response).to have_http_status(:created)

      # Adding again is idempotent, stays one Library entry and one Asset.
      post "/api/v1/assets/#{asset.id}/add_to_library", headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(user.library_items.count).to eq(1)

      get "/api/v1/library"
      items = JSON.parse(response.body)["items"]
      expect(items.size).to eq(1)
      expect(items.first["asset_id"]).to eq(asset.id)
      expect(user.assets.where(checksum: asset.checksum).count).to eq(1)
    end

    it "allows attaching a library asset to a message without a second upload" do
      asset = create(:asset, user: user)
      create(:library_item, user: user, asset: asset)
      bytes_before = asset.byte_size
      conversation = create(:conversation, user: user, agent: create(:agent))

      post "/api/v1/conversations/#{conversation.id}/messages",
           params: { content: "use this pdf", attachment_asset_ids: [ asset.id ] },
           headers: api_headers
      expect(response).to have_http_status(:created)

      expect(Asset.find(asset.id).byte_size).to eq(bytes_before)
      expect(user.assets.where(checksum: asset.checksum).count).to eq(1)
      expect(asset.reload.message_attachments.count).to eq(1)
    end
  end

  describe "downloads" do
    it "streams bytes to the owner with correct content-type" do
      asset = create(:asset, user: user, content_type: "text/plain", filename: "report.txt")
      Tempfile.create("download-") do |f|
        f.binmode
        f.write("download_body")
        f.rewind
        asset.file.attach(io: f, filename: "report.txt", content_type: "text/plain")
      end

      get "/api/v1/assets/#{asset.id}/download"
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("download_body")
      expect(response.headers["Content-Type"]).to include("text/plain")
    end

    it "never exposes another user's asset (404, no leak)" do
      foreign = create(:asset, user: other_user, checksum: SecureRandom.hex(32))
      get "/api/v1/assets/#{foreign.id}/download"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/assets/:id" do
    it "destroys own asset and removes bytes" do
      asset = create(:asset, user: user, checksum: SecureRandom.hex(32))
      Tempfile.create("purge-") do |f|
        f.binmode
        f.write("x")
        f.rewind
        asset.file.attach(io: f, filename: "a.txt", content_type: "text/plain")
      end
      key = asset.file.blob.key

      delete "/api/v1/assets/#{asset.id}", headers: api_headers
      expect(response).to have_http_status(:no_content)
      expect(ActiveStorage::Blob.find_by(key: key)).to be_nil
      expect { Asset.find(asset.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "refuses to destroy another user's asset" do
      foreign = create(:asset, user: other_user, checksum: SecureRandom.hex(32))
      delete "/api/v1/assets/#{foreign.id}", headers: api_headers
      expect(response).to have_http_status(:not_found)
      expect(Asset.exists?(foreign.id)).to be true
    end
  end

  describe "auto-library on upload" do
    it "provisions a LibraryItem the moment a file is ingested" do
      post "/api/v1/assets", params: { file: upload("budget.csv", "text/csv", "a,b\n1,2") },
                             headers: api_headers
      expect(response).to have_http_status(:created)

      asset = user.assets.find_by(filename: "budget.csv")
      expect(user.library_items.where(asset_id: asset.id).count).to eq(1)
      # It shows up in the Library listing without any manual add step.
      get "/api/v1/library"
      expect(JSON.parse(response.body)["items"].map { |i| i["asset_id"] }).to include(asset.id)
    end

    it "is idempotent on a re-upload of the same bytes (no duplicate rows)" do
      post "/api/v1/assets", params: { file: upload("dup.txt", "text/plain", "same content") },
                             headers: api_headers
      post "/api/v1/assets", params: { file: upload("dup.txt", "text/plain", "same content") },
                             headers: api_headers

      expect(user.assets.count).to eq(1)
      expect(user.library_items.count).to eq(1)
    end
  end

  describe "GET /api/v1 library search" do
    before do
      %w[quarterly-report.pdf team-retro.txt].each do |name|
        asset = create(:asset, user: user, filename: name, checksum: SecureRandom.hex(32))
        create(:library_item, user: user, asset: asset)
      end
    end

    it "filters by filename substring, case-insensitively" do
      get "/api/v1/library", params: { q: "REPORT" }
      names = JSON.parse(response.body)["items"].map { |i| i["filename"] }
      expect(names).to eq([ "quarterly-report.pdf" ])
    end

    it "returns everything when no query is given" do
      get "/api/v1/library"
      expect(JSON.parse(response.body)["items"].size).to eq(2)
    end

    it "escapes LIKE wildcards so a bare % does not match all" do
      get "/api/v1/library", params: { q: "%" }
      expect(JSON.parse(response.body)["items"]).to eq([])
    end
  end

  describe "GET /api/v1/assets/:id/preview" do
    it "returns the head of extracted text for a completed document" do
      asset = create(:asset, user: user, filename: "long.txt", checksum: SecureRandom.hex(32))
      create(:asset_extraction, asset: asset, status: "completed",
                                content: "X" * 3_000, meta: {})

      get "/api/v1/assets/#{asset.id}/preview"
      json = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(json["extraction"]["status"]).to eq("completed")
      expect(json["extraction"]["preview"].length).to eq(2_000)
      expect(json["extraction"]["truncated"]).to be true
      expect(json["asset"]["image"]).to be false
    end

    it "flags images and exposes the authorized download URL" do
      asset = create(:asset, user: user, content_type: "image/png", filename: "shot.png",
                             checksum: SecureRandom.hex(32), metadata: { "category" => "image" })
      create(:asset_extraction, asset: asset, status: "completed", content: "", meta: {})

      get "/api/v1/assets/#{asset.id}/preview"
      json = JSON.parse(response.body)
      expect(json["asset"]["image"]).to be true
      expect(json["asset"]["download_url"]).to eq("/api/v1/assets/#{asset.id}/download")
    end

    it "reports pending extraction without leaking partial content" do
      asset = create(:asset, user: user, checksum: SecureRandom.hex(32))
      create(:asset_extraction, asset: asset, status: "processing", content: nil, meta: {})

      get "/api/v1/assets/#{asset.id}/preview"
      json = JSON.parse(response.body)
      expect(json["extraction"]["status"]).to eq("processing")
      expect(json["extraction"]["preview"]).to eq("")
    end

    it "never previews another user's asset" do
      foreign = create(:asset, user: other_user, checksum: SecureRandom.hex(32))
      get "/api/v1/assets/#{foreign.id}/preview"
      expect(response).to have_http_status(:not_found)
    end
  end
end
