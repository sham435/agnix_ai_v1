# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe Assets::Validator do
  def png_image_bytes
    "\x89PNG\r\n\x1a\n" + ("image bytes" * 3)
  end

  def validate_for(filename:, bytes:, declared: nil)
    described_class.validate(text_file(bytes), filename: filename, declared_mime: declared)
  end

  it "accepts a real png image by magic bytes" do
    result = validate_for(filename: "shot.png", bytes: png_image_bytes, declared: "application/octet-stream")
    expect(result).to be_ok
    expect(result.category).to eq("image")
    expect(result.content_type).to eq("image/png")
  end

  it "rejects a fake png (text bytes with .png extension)" do
    result = validate_for(filename: "fake.png", bytes: "pretend this is an image")
    expect(result).not_to be_ok
    expect(result.error_code).to eq(:mime_mismatch)
  end

  it "rejects a fake pdf (zip bytes pretending to be pdf)" do
    result = validate_for(filename: "doc.pdf", bytes: "\x89PNG\r\n\x1a\nwhatever")
    expect(result.error_code).to eq(:mime_mismatch)
  end

  it "rejects executables by extension" do
    result = validate_for(filename: "virus.exe", bytes: "MZbinary")
    expect(result.error_code).to eq(:executable_forbidden)
  end

  it "rejects double-extension smuggling (.svg.exe)" do
    result = validate_for(filename: "photo.svg.exe", bytes: "MZ")
    expect(result.error_code).to eq(:executable_forbidden)
  end

  it "rejects unsupported types" do
    expect(validate_for(filename: "thing.zip", bytes: "PK\x03\x04").error_code).to eq(:unsupported_type)
    expect(validate_for(filename: "notes.sh", bytes: "#!/bin/sh").error_code).to eq(:unsupported_type)
  end

  it "rejects empty and missing uploads" do
    expect(validate_for(filename: "empty.txt", bytes: "").error_code).to eq(:empty_file)
    expect(described_class.validate(nil, filename: "x.txt")).not_to be_ok
    expect(described_class.validate(nil, filename: nil).error_code).to eq(:file_missing)
  end

  it "enforces size caps (25MB general, 10MB images)" do
    expect(validate_for(filename: "big.txt", bytes: "x" * (25.megabytes + 1)).error_code).to eq(:too_large)
    expect(validate_for(filename: "big.png", bytes: png_image_bytes + "x" * (10.megabytes)).error_code).to eq(:too_large)
  end

  it "accepts text, markdown, code and csv as text-like" do
    %w[notes.txt readme.md app.py data.csv].each do |name|
      result = validate_for(filename: name, bytes: "plain text content")
      expect(result).to be_ok
    end
  end

  it "rejects binary-looking content claiming to be text" do
    binary = ("\x00\x01" * 40) + "text"
    expect(validate_for(filename: "corp.txt", bytes: binary).error_code).to eq(:mime_mismatch)
  end

  it "keeps one allowlist as the single source of truth" do
    expect(described_class::ALLOWED.keys).to include("pdf", "docx", "xlsx", "csv", "md", "rb", "py")
    expect(described_class::FORBIDDEN_EXTENSIONS).to include("exe", "dll", "dylib")
  end
end
