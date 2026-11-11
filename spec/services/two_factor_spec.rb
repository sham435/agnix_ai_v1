# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations

RSpec.describe TwoFactor do
  let(:user) { build(:user, email: "owner@example.com") }
  let(:secret) { "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" }
  let(:service) { described_class.new(user, secret: secret) }

  describe "#valid?" do
    it "accepts the code for the current window" do
      expect(service.valid?(ROTP::TOTP.new(secret).now)).to be(true)
    end

    it "accepts the previous window so a skewed clock still signs in" do
      expect(service.valid?(ROTP::TOTP.new(secret).at(25.seconds.ago))).to be(true)
    end

    it "rejects a stale code, junk, blanks and a user with no secret" do
      stale = ROTP::TOTP.new(secret).at(2.minutes.ago)

      expect(service.valid?(stale)).to be(false)
      expect(service.valid?("000000")).to be(false)
      expect(service.valid?(nil)).to be(false)
      expect(described_class.new(user).valid?("123456")).to be(false)
    end

    it "accepts a code pasted with spaces or a dash in it" do
      code = ROTP::TOTP.new(secret).now

      expect(service.valid?(" #{code} ")).to be(true)
      expect(service.valid?(code.chars.join("-"))).to be(true)
    end
  end

  describe "#provisioning_uri" do
    it "names the account the code belongs to" do
      expect(service.provisioning_uri).to start_with("otpauth://totp/Shams%20AI:owner%40example.com?secret=")
    end
  end

  describe "#qr_svg" do
    it "renders an inline SVG with no XML prologue" do
      svg = service.qr_svg

      expect(svg).to start_with("<svg")
      expect(svg).not_to include("<?xml")
      expect(svg).to include("</svg>")
    end

    it "escapes the email before putting it in an attribute" do
      user.email = "odd\"quote@example.com"

      expect(service.qr_svg).not_to include('aria-label="QR code for odd"quote')
    end
  end

  describe ".generate_secret" do
    it "makes a fresh base32 secret each call" do
      secrets = Array.new(3) { described_class.generate_secret }

      expect(secrets.uniq.size).to eq(3)
      expect(secrets).to all(match(/\A[A-Z2-7]{32}\z/))
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations
