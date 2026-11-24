# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Assets::Ingest do
  let(:user) { create(:user) }
  let(:upload) do
    ActionDispatch::Http::UploadedFile.new({
      tempfile: file,
      filename: "notes.txt",
      type: "text/plain"
    })
  end
  let(:file) { Tempfile.new.tap { |f| f.write("hello ingest world\n"); f.rewind; f } }
  let(:image_file) do
    Tempfile.new.tap do |tempfile|
      tempfile.binmode
      tempfile.write("\x89PNG\r\n\x1a\nimage bytes")
      tempfile.rewind
    end
  end
  let(:image_upload) do
    ActionDispatch::Http::UploadedFile.new({
      tempfile: image_file,
      filename: "image.png",
      type: "image/png"
    })
  end

  after do
    [ file, image_file ].each { |tempfile| tempfile.close! if tempfile.is_a?(Tempfile) }
  end

  it "ingests a valid upload into asset + extraction (inline adapter executes it now)" do
    result = described_class.call(user: user, upload: upload)

    expect(result.created?).to be true
    expect(result.asset.status).to eq("ready")
    expect(result.asset.metadata["category"]).to eq("text")
    expect(result.asset.file).to be_attached
    # Test queue adapter is :inline — perform_later executes now, so the
    # extraction has already moved out of pending.
    expect(result.extraction.reload.status).to include('completed')
  end

  it "dedupes identical bytes: second ingest resolves to the existing asset without re-saving" do
    first = described_class.call(user: user, upload: upload)
    second = described_class.call(user: user, upload: upload)

    expect(second.created?).to be false
    expect(second.asset.id).to eq(first.asset.id)
    expect(user.assets.count).to eq(1)
  end

  it "does not reuse a ready image checksum row with no attachment" do
    create(:asset, user: user, filename: "missing.png", content_type: "image/png",
                  checksum: Digest::SHA256.hexdigest("\x89PNG\r\n\x1a\nimage bytes"),
                  metadata: { "category" => "image", "ext" => "png" })

    expect { described_class.call(user: user, upload: image_upload) }
      .to raise_error(Assets::Ingest::InvalidUpload) { |error| expect(error.error_code).to eq(:attachment_missing) }
    expect(user.assets.count).to eq(1)
    expect(LibraryItem.exists?(user: user, asset: user.assets.first)).to be(false)
  end

  it "rolls back the ready asset when Active Storage upload fails" do
    counts = [ Asset.count, AssetExtraction.count, LibraryItem.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_raise(ActiveStorage::IntegrityError)

    expect { described_class.call(user: user, upload: upload) }.to raise_error(ActiveStorage::IntegrityError)

    expect([ Asset.count, AssetExtraction.count, LibraryItem.count, ActiveStorage::Blob.count,
             ActiveStorage::Attachment.count ]).to eq(counts)
    expect(Asset.exists?(user: user, checksum: Digest::SHA256.hexdigest("hello ingest world\n"))).to be(false)
  end

  it "rolls back asset, attachment, extraction and library when enqueue fails, allowing a clean retry" do
    counts = [ Asset.count, AssetExtraction.count, LibraryItem.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    allow(AssetExtractionJob).to receive(:perform_later).and_return(false)

    expect { described_class.call(user: user, upload: upload) }.to raise_error(ActiveJob::EnqueueError)

    expect([ Asset.count, AssetExtraction.count, LibraryItem.count, ActiveStorage::Blob.count,
             ActiveStorage::Attachment.count ]).to eq(counts)
    expect(Asset.exists?(user: user, checksum: Digest::SHA256.hexdigest("hello ingest world\n"))).to be(false)

    allow(AssetExtractionJob).to receive(:perform_later).and_call_original
    result = described_class.call(user: user, upload: upload)
    expect(result.created?).to be(true)
    expect(result.asset.file).to be_attached
  end

  it "same bytes from a different user create a separate asset" do
    described_class.call(user: user, upload: upload)
    other = create(:user)
    result = described_class.call(user: other, upload: upload)
    expect(result.created?).to be true
    expect(other.assets.count).to eq(1)
  end

  it "rejects executables and fake mime uploads" do
    csv_fakes = {
      "virus.exe" => :executable_forbidden,
      "fake.png" => :mime_mismatch
    }
    csv_fakes.each do |name, code|
      body = name.end_with?(".png") ? "not really a png" : "MZ payload"
      bad = ActionDispatch::Http::UploadedFile.new(
        tempfile: StringIO.new(body),
        filename: name,
        type: "application/octet-stream"
      )
      expect { described_class.call(user: user, upload: bad) }
        .to raise_error(Assets::Ingest::InvalidUpload) { |e| expect(e.error_code).to eq(code) }
    end
  end

  it "attaches uploaded assets to the given project only when owned" do
    project = create(:project, user: user, agent: create(:agent))
    result = described_class.call(user: user, upload: upload, project: project)
    expect(result.asset.project_id).to eq(project.id)

    foreign = create(:project, user: create(:user), agent: create(:agent))
    expect { described_class.call(user: user, upload: upload, project: foreign) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
