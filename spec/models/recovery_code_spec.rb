# frozen_string_literal: true

require "rails_helper"

# Backup codes: one string the user keeps, one hash the database keeps.
# rubocop:disable RSpec/MultipleExpectations

RSpec.describe RecoveryCode do
  subject(:user) { create(:user) }

  describe ".generate!" do
    it "hands back the codes and stores only their digests" do
      codes = described_class.generate!(user)

      expect(codes).to have_attributes(size: described_class::COUNT)
      expect(codes).to all(match(/\A[A-Z2-9]{10}\z/))
      expect(user.reload.recovery_codes.pluck(:code_digest))
        .to all(match(/\A\h{64}\z/))
    end

    it "never stores a plaintext code anywhere on the row" do
      code = described_class.generate!(user).first
      row = user.recovery_codes.find_by(code_digest: described_class.digest(code))

      expect(row.as_json.keys).not_to include("code")
      expect(row.to_param).to eq(row.id.to_s)
    end

    it "retires the previous set, so only one list is ever live" do
      stale = described_class.generate!(user).first
      fresh = described_class.generate!(user)

      expect(described_class.consume!(user, stale)).to be_nil
      expect(described_class.consume!(user, fresh.first)).to be_present
      expect(user.reload.recovery_codes.unused.count).to eq(described_class::COUNT - 1)
    end

    it "uses an alphabet with nothing that gets misread off a screenshot" do
      codes = described_class.generate!(user) + described_class.generate!(user)

      expect(codes.join).not_to match(/[01OIL]/)
    end
  end

  describe ".consume!" do
    let!(:code) { described_class.generate!(user).first }

    it "returns the row once and marks it spent" do
      row = described_class.consume!(user, code)

      expect(row).to be_persisted
      expect(row.consumed?).to be(true)
      expect(described_class.consume!(user, code)).to be_nil
    end

    it "accepts the code as it is read back: lower case, dashed, or spaced" do
      expect(described_class.consume!(user, "  #{code.downcase}  ")).to be_present
    end

    it "accepts the printed form with its dash in it" do
      expect(described_class.consume!(user, described_class.format(code))).to be_present
    end

    it "refuses anything else without spending a code" do
      expect(described_class.consume!(user, "2K4QX7ZR9T")).to be_nil
      expect(described_class.consume!(user, "")).to be_nil
      expect(described_class.consume!(user, nil)).to be_nil
      expect(user.reload.recovery_codes.unused.count).to eq(described_class::COUNT)
    end

    it "cannot spend another account's code" do
      stranger = create(:user)
      described_class.generate!(stranger)

      expect(described_class.consume!(stranger, code)).to be_nil
      expect(described_class.consume!(user, code)).to be_present
    end

    it "spends a code once when two requests race on it" do
      # One row, two would-be sign-ins. The scoped UPDATE is what decides, so
      # exactly one caller may be told it got in.
      results = Array.new(4) { Thread.new { described_class.consume!(user.reload, code) } }.map(&:value)

      expect(results.compact).to have_attributes(size: 1)
    end
  end

  describe ".digest" do
    it "is the same hash the lookup uses, whatever the typing" do
      expect(described_class.digest(" 2k4qx7zr9t ")).to eq(described_class.digest("2K4QX7ZR9T"))
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations
