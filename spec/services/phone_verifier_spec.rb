# frozen_string_literal: true

require "rails_helper"

# Phone verification's policy layer. The test environment runs the `dev` SMS
# driver, which "delivers" by handing the code back - the same rows, windows and
# verdicts a real gateway would produce.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

RSpec.describe PhoneVerifier do
  subject(:user) { create(:user) }

  let(:phone) { "+94771234567" }

  def request_as(other = user, raw_phone = phone, ip: nil)
    described_class.request(other, phone: raw_phone, ip: ip)
  end

  describe "the number" do
    it "is refused before anything is written when it is not one" do
      result = request_as(user, "not a number")

      expect(result.status).to eq(:invalid_number)
      expect(PhoneVerification.count).to eq(0)
      expect(user.reload.phone).to be_nil
    end

    it "accepts the ways people actually type it" do
      [ "+94 77 123 4567", "+94-77-123-4567", "0094 77 123 4567" ].each do |raw|
        user.phone_verifications.delete_all
        result = request_as(user, raw)

        expect(result.status).to eq(:sent), "#{raw} was refused"
        # Stored as E.164 whatever the typing, so the send budget counts one
        # number rather than five spellings of it.
        expect(user.phone_verifications.order(:id).last.phone).to eq(phone)
      end
    end

    it "refuses a number it would have to guess a country for" do
      expect(request_as(user, "771234567").status).to eq(:invalid_number)
    end
  end

  describe ".request" do
    it "issues a code and says how long the wait for the next one is" do
      result = request_as

      expect(result.status).to eq(:sent)
      expect(result.code).to match(/\A\d{6}\z/)
      expect(result.retry_in).to eq(PhoneVerification::RESEND_COOLDOWN.to_i)
      expect(user.phone_verifications.count).to eq(1)
    end

    it "keeps a second request inside the cooldown from sending again" do
      request_as

      second = request_as

      expect(second.status).to eq(:cooldown)
      expect(second.retry_in).to be_between(1, PhoneVerification::RESEND_COOLDOWN.to_i)
      expect(user.phone_verifications.count).to eq(1)
    end

    it "sends again once the cooldown has run out" do
      request_as

      travel_to(Time.current + PhoneVerification::RESEND_COOLDOWN + 1.second) do
        expect(request_as.status).to eq(:sent)
      end
    end

    it "stops after the hourly budget for this account" do
      fill_window

      expect(request_as.status).to eq(:limited)
    end

    it "counts another account's sends to the same number" do
      stranger = create(:user)
      fill_window(stranger)

      expect(request_as(user, phone).status).to eq(:limited)
    end

    it "counts sends from one address across accounts" do
      fill_window(user, ip: "203.0.113.9")

      expect(request_as(create(:user), "+94779998888", ip: "203.0.113.9").status).to eq(:limited)
    end

    it "says so when the server has no way to deliver a code" do
      allow(SmsService).to receive(:driver).and_return("none")

      result = request_as

      expect(result.status).to eq(:unconfigured)
      expect(result.message).to eq(SmsService::NOT_CONFIGURED)
      expect(user.phone_verifications.count).to eq(0)
    end

    it "throws the code away when the gateway fails to send it" do
      allow(SmsService).to receive(:deliver).and_return({ ok: false, error: "Gateway said no" })

      result = request_as

      expect(result.status).to eq(:undelivered)
      expect(result.message).to eq("Gateway said no")
      expect(user.phone_verifications.count).to eq(0)
    end

    it "keeps the code out of what a failure reports" do
      allow(SmsService).to receive(:deliver).and_return({ ok: false, error: "Gateway said no" })

      result = request_as

      expect(result.code).to be_nil
      expect(result.message).to eq("Gateway said no")
      expect(result.message).not_to match(/\d{6}/)
    end
  end

  describe ".confirm" do
    it "answers that nothing was sent when there is no code" do
      expect(described_class.confirm(user, code: "123456").status).to eq(:no_code)
    end

    it "verifies the number and stamps the account" do
      code = request_as.code

      result = described_class.confirm(user, code: code)

      expect(result.status).to eq(:verified)
      expect(user.reload.phone).to eq(phone)
      expect(user.phone_verified_at).to be_present
      expect(user.phone_verifications.last.consumed?).to be(true)
    end

    it "counts down the guesses it allows" do
      request_as

      first = described_class.confirm(user, code: "000000")

      expect(first.status).to eq(:invalid)
      expect(first.message).to include("#{PhoneVerification::MAX_ATTEMPTS - 1} tries left")
    end

    it "kills the code after the budget instead of waiting for more guesses" do
      request_as
      Array.new(PhoneVerification::MAX_ATTEMPTS) { described_class.confirm(user, code: "000000") }

      last = described_class.confirm(user, code: "000000")

      expect(last.status).to eq(:exhausted)
    end

    it "refuses a code after its time has passed" do
      code = request_as.code

      travel_to(Time.current + PhoneVerification::TTL + 1.second) do
        expect(described_class.confirm(user, code: code).status).to eq(:expired)
      end
    end

    it "answers that nothing was sent once the code has been spent" do
      code = request_as.code
      described_class.confirm(user, code: code)

      # A spent row is out of the running: #current_for only looks at rows that
      # can still be verified, so the honest answer to a second try is "there is
      # no open code". Keeping it that way is what lets a fresh request go
      # through right away instead of hitting the old row's cooldown.
      expect(described_class.confirm(user, code: code).status).to eq(:no_code)
      expect(user.reload.phone).to eq(phone)
    end

    it "does not verify someone else's code" do
      code = request_as.code
      stranger = create(:user)

      expect(described_class.confirm(stranger, code: code).status).to eq(:no_code)
      expect(stranger.reload.phone).to be_nil
    end
  end

  describe "an SMS code and the sign-in factor" do
    it "stays out of the sign-in path" do
      TwoFactor.activate!(user, TwoFactor.generate_secret)
      code = request_as.code

      expect(TwoFactorLogin.verify(user: user, code: code).status).to eq(:invalid)
    end
  end

  private

  # The sending window, filled with rows old enough to skip the resend cooldown
  # but inside the hour the budget counts.
  def fill_window(for_user = user, ip: nil)
    PhoneVerification::MAX_SENDS_PER_WINDOW.times do
      for_user.phone_verifications.create!(
        phone: phone, channel: "dev", ip: ip, code: "123456",
        created_at: 2.minutes.ago, expires_at: 3.minutes.from_now
      )
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
