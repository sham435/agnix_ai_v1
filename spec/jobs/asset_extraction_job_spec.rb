# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe AssetExtractionJob do
  it "marks completed with extractor output" do
    asset = create(:asset, metadata: { "category" => "text", "ext" => "txt" })
    Tempfile.create("job-spec-") do |f|
      f.write("job extraction text")
      f.rewind
      asset.file.attach(io: f, filename: "t.txt", content_type: "text/plain")
    end
    extraction = create(:asset_extraction, asset: asset, status: "pending")

    described_class.perform_now(extraction.id)

    extraction.reload
    expect(extraction.status).to eq("completed")
    expect(extraction.error_code).to be_nil
    expect(extraction.meta["extractor"]).to eq("text")
  end

  it "fails with a safe error code on malformed content" do
    asset = create(:asset, metadata: { "category" => "spreadsheet", "ext" => "xlsx" })
    Tempfile.create("job-spec-bad-") do |f|
      f.write("junk-not-zip")
      f.rewind
      asset.file.attach(io: f, filename: "b.xlsx", content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    end
    extraction = create(:asset_extraction, asset: asset, status: "pending")

    described_class.perform_now(extraction.id)

    extraction.reload
    expect(extraction.status).to eq("failed")
    expect(extraction.error_code).to eq("malformed_archive")
    expect(extraction.content).to be_nil
    # Safe vocabulary only — the raw message never lands on the record.
    expect(extraction.error_code).not_to include("junk")
  end

  it "collapses unexpected errors to extraction_error" do
    asset = create(:asset, metadata: { "category" => "text", "ext" => "txt" })
    extraction = create(:asset_extraction, asset: asset, status: "pending")
    allow(Assets::Extractors).to receive(:run_for).and_raise("boom-raw")
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(extraction.id)

    extraction.reload
    expect(extraction.status).to eq("failed")
    expect(extraction.error_code).to eq("extraction_error")
  end

  it "is a no-op when the extraction is missing or already completed" do
    asset = create(:asset, metadata: { "category" => "text", "ext" => "txt" })
    extraction = create(:asset_extraction, asset: asset, status: "completed", content: "done")

    described_class.perform_now(extraction.id)
    extraction.reload
    expect(extraction.content).to eq("done")

    described_class.perform_now("does-not-exist") # no raise
  end
end
