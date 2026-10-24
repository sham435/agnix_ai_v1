# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

RSpec.describe AssetExtraction do
  it { expect(build(:asset_extraction)).to be_valid }
  it { expect(build(:asset_extraction, status: "weird")).not_to be_valid }
  it { expect(build(:asset_extraction, error_code: "raw_exception_text")).not_to be_valid }
  it { expect(build(:asset_extraction, error_code: "parse_error")).to be_valid }
  it { expect(build(:asset_extraction, content: "x" * 200_001)).not_to be_valid }
  it { expect(build(:asset_extraction, content: nil)).to be_valid }

  it "rejects non-hash meta" do
    extraction = build(:asset_extraction)
    extraction.write_attribute(:meta, [ { bad: 1 } ])
    expect(extraction).not_to be_valid
    expect(extraction.errors[:meta]).to be_present
  end

  it "allows one extraction row per asset" do
    asset = create(:asset)
    create(:asset_extraction, asset: asset, status: "completed")
    expect { build(:asset_extraction, asset: asset).save!(validate: false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "scopes helpers by status" do
    asset = create(:asset)
    create(:asset_extraction, asset: asset, status: "pending")
    create(:asset_extraction, asset: create(:asset), status: "completed")

    expect(described_class.completed.count).to eq(1)
    expect(described_class.pending_or_processing.count).to eq(1)
  end
end
