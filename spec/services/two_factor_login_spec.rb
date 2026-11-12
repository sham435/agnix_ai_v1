# frozen_string_literal: true

require "rails_helper"

# The sign-in decision, in one class and on the server. Everything a client is
# allowed to know is what this returns: verified, refused, or paused.
# rubocop:disable RSpec/MultipleExpectations

RSpec.describe TwoFactorLogin do
  subject(:login) { described_class.new(user) }

  let(:user) { create(:user) }
  let(:secret) { TwoFactor.generate_secret }
  let(:totp) { ROTP::TOTP.new(secret) }

  before { TwoFactor.activate!(user, secret) }

  describe "#verify with an authenticator code" do
    it "accepts the current code and clears the failure counter" do
      user.update!(otp_failed_attempts: 2)

      result = login.verify(totp.now)

      expect(result.status).to eq(:verified)
      expect(user.reload.otp_failed_attempts).to eq(0)
      expect(user.otp_locked_until).to be_nil
    end

    it "refuses a code built from another account's key" do
      expect(login.verify(ROTP::TOTP.new(TwoFactor.generate_secret).now).status).to eq(:invalid)
    end

    it "refuses the same code twice, inside its own validity window" do
      code = totp.now

      expect(login.verify(code).status).to eq(:verified)
      # The string is still valid as far as ROTP is concerned for another 30
      # seconds; the recorded step is what makes it one-use.
      expect(login.verify(code).status).to eq(:invalid)
    end

    it "accepts the next step after the one it accepted" do
      expect(login.verify(totp.at(Time.current)).status).to eq(:verified)

      travel_to(31.seconds.from_now) do
        expect(login.verify(totp.now).status).to eq(:verified)
      end
    end

    it "reads a code typed with a space or a dash as the same six digits" do
      code = totp.now

      expect(login.verify("#{code[0, 3]} #{code[3, 4]}").status).to eq(:verified)
    end

    it "refuses a blank without changing the account" do
      expect(login.verify(nil).status).to eq(:invalid)
      expect(login.verify("   ").status).to eq(:invalid)
      expect(user.reload.otp_enabled).to be(true)
    end
  end

  describe "#verify with a backup code" do
    it "accepts one and counts what is left" do
      plaintext = RecoveryCode.generate!(user).first

      result = login.verify(plaintext)

      expect(result.status).to eq(:recovery_used)
      expect(result.recovery_codes_left).to eq(RecoveryCode::COUNT - 1)
    end

    it "refuses a code that was already spent" do
      plaintext = RecoveryCode.generate!(user).first
      expect(login.verify(plaintext).status).to eq(:recovery_used)

      expect(login.verify(plaintext).status).to eq(:invalid)
    end

    it "reads a code in lower case, or with spaces around it" do
      plaintext = RecoveryCode.generate!(user).first

      expect(login.verify(" #{plaintext.downcase} ").status).to eq(:recovery_used)
    end
  end

  describe "guessing" do
    it "locks the factor after the budget and then refuses even a good code" do
      statuses = Array.new(User::MAX_SECOND_FACTOR_ATTEMPTS) { login.verify("000000").status }

      expect(statuses.last).to eq(:locked)
      expect(user.reload.two_factor_locked?).to be(true)

      # The lock is the answer for the whole window, whatever is typed at it.
      expect(login.verify(totp.now).status).to eq(:locked)
      expect(login.verify(RecoveryCode.generate!(user).first).status).to eq(:locked)
    end

    it "counts both kinds of guess against the same budget" do
      (User::MAX_SECOND_FACTOR_ATTEMPTS - 1).times { login.verify("000000") }
      expect(user.reload.otp_failed_attempts).to eq(User::MAX_SECOND_FACTOR_ATTEMPTS - 1)

      expect(login.verify("ZZZZZZZZZZ").status).to eq(:locked)
    end

    it "reports the minutes it is paused for" do
      statuses = Array.new(User::MAX_SECOND_FACTOR_ATTEMPTS) { login.verify("000000") }

      expect(statuses.last.minutes_left).to eq(User::SECOND_FACTOR_LOCKOUT / 60)
    end

    it "lets a good code back in once the window has passed" do
      User::MAX_SECOND_FACTOR_ATTEMPTS.times { login.verify("000000") }
      expect(user.reload.two_factor_locked?).to be(true)

      travel_to(Time.current + User::SECOND_FACTOR_LOCKOUT + 1.second) do
        expect(login.verify(totp.now).status).to eq(:verified)
      end
    end
  end

  describe "what a phone code cannot do" do
    it "refuses the six digits an SMS verification issued" do
      row = PhoneVerification.issue!(user, phone: "+94771234567", channel: "dev")

      # Same shape as a TOTP, so it is tried as one and fails: holding a number
      # is a different claim from being this account, and the two are never
      # interchangeable at sign-in.
      expect(login.verify(row.code).status).to eq(:invalid)
    end
  end

  describe "one account's factor cannot open another's" do
    it "refuses a stranger's backup code and leaves it unspent" do
      stranger = create(:user)
      codes = RecoveryCode.generate!(stranger)

      expect(login.verify(codes.first).status).to eq(:invalid)
      expect(stranger.reload.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations
