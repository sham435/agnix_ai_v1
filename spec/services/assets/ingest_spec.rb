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

  after do
    file.close! if defined?(file) && file.is_a?(Tempfile)
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
