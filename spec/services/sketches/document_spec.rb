# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sketches::Document do
  let(:document) { { width: 64, height: 48, shapes: [] } }

  it "canonicalizes key order, symbols and integral numbers" do
    shape = { type: "circle", cx: 10.0, cy: 12, r: 3, fill: "#ABCDEF" }
    first = described_class.call(document: document.merge(shapes: [ shape ]))
    second = described_class.call(document: JSON.parse(first.json).to_a.reverse.to_h)
    expect([ first.json, first.svg ]).to eq([ second.json, second.svg ])
  end

  it "escapes text markup rather than creating elements or references" do # rubocop:disable RSpec/MultipleExpectations
    result = described_class.call(document: document.merge(shapes: [
      { type: "text", x: 0, y: 20, text: '<script>&"</script><image href="https://evil"/>', fill: "black", font_size: 12 }
    ]))
    expect(result.svg).to include("&lt;script&gt;&amp;&quot;")
    expect(result.svg).not_to include("<script", "<image", "<!DOCTYPE")
  end

  [
    { width: 1025 }, { height: 0 }, { width: Float::INFINITY },
    { shapes: Array.new(101) { {} } }, { shapes: "<svg/>" },
    { shapes: [ { type: "image", href: "file:///etc/passwd" } ] },
    { shapes: [ { type: "circle", cx: Float::NAN, cy: 0, r: 1, fill: "red" } ] },
    { shapes: [ { type: "circle", cx: -1, cy: 0, r: 1, fill: "red" } ] },
    { shapes: [ { type: "circle", cx: 0, cy: 0, r: 1025, fill: "red" } ] },
    { shapes: [ { type: "circle", cx: 0, cy: 0, r: 1, fill: "url(https://evil)" } ] },
    { shapes: [ { type: "circle", cx: 0, cy: 0, r: 1, fill: "red", onclick: "evil()" } ] },
    { shapes: [ { type: "text", x: 0, y: 0, text: "a" * 201, fill: "black", font_size: 12 } ] },
    { shapes: [ { type: "text", x: 0, y: 0, text: "\u0000", fill: "black", font_size: 12 } ] }
  ].each_with_index do |invalid, index|
    it "rejects unsafe or unbounded document #{index}" do
      expect { described_class.call(document: document.merge(invalid)) }
        .to raise_error(described_class::InvalidDocument)
    end
  end

  it "rejects raw JSON, XML and arbitrary SVG inputs" do
    [ '{"width":1}', "<!DOCTYPE svg><svg/>", "<svg/>" ].each do |input|
      expect { described_class.call(document: input) }.to raise_error(described_class::InvalidDocument)
    end
  end
end
