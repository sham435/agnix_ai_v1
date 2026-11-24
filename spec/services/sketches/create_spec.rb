# frozen_string_literal: true

# Integration examples verify the complete reproducible ingest contract.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength
require "rails_helper"

RSpec.describe Sketches::Create do
  let(:user) { create(:user) }
  let(:document) do
    { width: 64, height: 48, shapes: [
      { type: "rect", x: 0, y: 0, width: 64, height: 48, fill: "white" },
      { type: "circle", cx: 20, cy: 20, r: 10, fill: "red" },
      { type: "line", x1: 0, y1: 0, x2: 64, y2: 48, stroke: "blue", stroke_width: 2 },
      { type: "text", x: 5, y: 40, text: "Safe & sound", fill: "black", font_size: 10 }
    ] }
  end

  before do |example|
    next if example.metadata[:without_backend]

    skip "Local SVG renderer unavailable" unless described_class.available?
  end

  it "renders real deterministic PNG bytes, stores provenance and populates the Library" do
    first = described_class.call(user: user, document: document)
    second = described_class.call(user: user, document: JSON.parse(first.json))
    bytes = first.asset.file.download
    expect(bytes.b).to start_with("\x89PNG\r\n\x1a\n".b)
    expect(bytes.byteslice(16, 8).unpack("NN")).to eq([ 64, 48 ])
    expect(second.asset.file.download).to eq(bytes)
    expect(second.asset.id).to eq(first.asset.id)
    expect(second.svg).to eq(first.svg)
    expect(first.asset.reload.metadata).to include("category" => "image", "ext" => "png")
    expect(first.asset.metadata.fetch("sketch")).to eq("json" => first.json, "svg" => first.svg)
    expect(user.library_items.exists?(asset: first.asset)).to be true
  end

  it "does not overwrite unrelated or existing provenance on deduplication" do
    first = described_class.call(user: user, document: document)
    first.asset.update!(metadata: first.asset.metadata.merge("custom" => "preserved", "sketch" => { "original" => true }))
    again = described_class.call(user: user, document: document)
    expect(again.asset.metadata).to include("custom" => "preserved", "sketch" => { "original" => true })
  end

  it "keeps identical previews owned separately for separate users" do
    first = described_class.call(user: user, document: document)
    other = create(:user)
    second = described_class.call(user: other, document: document)
    expect(second.asset.id).not_to eq(first.asset.id)
    expect(second.asset.user).to eq(other)
    expect(second.asset.checksum).to eq(first.asset.checksum)
    expect(second.asset.readable_by?(user)).to be_falsey
  end

  it "fails honestly without ingesting when the renderer fails" do
    allow_any_instance_of(described_class).to receive(:rasterize)
      .and_raise(described_class::RenderingUnavailable, "SVG loader unavailable")
    allow(Assets::Ingest).to receive(:call)
    expect { described_class.call(user: user, document: document) }
      .to raise_error(described_class::RenderingUnavailable, /SVG loader unavailable/)
    expect(Assets::Ingest).not_to have_received(:call)
  end

  context "without a native library", :without_backend do
    before do
      service = described_class.new(user: nil, document: { width: 1, height: 1, shapes: [] })
      allow(described_class).to receive(:new).and_return(service)
      allow(service).to receive(:require).with("vips").and_raise(LoadError, "native library missing")
      allow(File).to receive(:executable?).and_return(false)
      allow(Assets::Ingest).to receive(:call)
    end

    it "raises a domain error before ingest" do
      expect { described_class.call(user: nil, document: {}) }
        .to raise_error(described_class::RenderingUnavailable, /Install libvips or librsvg/)
      expect(Assets::Ingest).not_to have_received(:call)
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
