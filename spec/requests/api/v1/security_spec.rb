# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"

# The security panel's data endpoints — what the mobile app reads and acts on.
# The rules under test are the panel's own, seen from the other side of the
# wire: a code has to be proved before the account changes, backup codes leave
# the server once, a password costs the factor its removal, and the stored key
# is never handed to anyone.
RSpec.describe "API v1 security", type: :request do
  let(:user) { create(:user) }
  let(:secret) { "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" }

  def json = JSON.parse(response.body)

  def code_for(totp_secret)
    ROTP::TOTP.new(totp_secret).now
  end

  # Enrollment through the API, as a client that means to finish it.
  def start_enrollment
    api_login(user)
    post "/api/v1/security/two_factor", headers: api_headers
    json.fetch("enrollment")
  end

  describe "reading the panel" do
    it "does not answer a visitor" do
      get "/api/v1/security"

      expect(response).to have_http_status(:unauthorized)
    end

    it "reports the state a signed-in client has to draw" do
      api_login(user)
      get "/api/v1/security"

      expect(response).to have_http_status(:ok)
      expect(json["two_factor"]).to include("enabled" => false, "recovery_codes_left" => 0)
      expect(json["phone"]).to include("verified" => false)
      expect(json["usage"]["plan"]).to eq("free")
      # A plan with no daily ceiling is unmetered, not "zero left".
      expect(json["usage"]).to include("metered" => false, "cap" => nil, "remaining" => nil)
      expect(json["devices"].map { |d| d["current"] }).to eq([ true ])
      expect(json["devices"].first["device"]).to eq("Unknown device")
    end
  end

  describe "enrollment" do
    it "offers a key without touching the account" do
      enrollment = start_enrollment

      expect(response).to have_http_status(:ok)
      expect(enrollment["secret"]).to match(/\A[A-Z2-7]{32}\z/)
      expect(enrollment["provisioning_uri"]).to start_with("otpauth://totp/Shams")
      expect(enrollment["expires_in"]).to eq(TwoFactor::ENROLLMENT_TTL.to_i)
      expect(json["two_factor"]["enabled"]).to be(false)
      expect(user.reload).not_to be_second_factor_enabled
      expect(user.recovery_codes.count).to eq(0)
    end

    it "refuses to start a second enrollment over an enabled factor" do
      enroll_over_api

      post "/api/v1/security/two_factor", headers: api_headers

      expect(response).to have_http_status(:conflict)
      expect(json).not_to have_key("enrollment")
    end

    it "keeps the account unchanged until a code built from the key arrives" do
      enrollment = start_enrollment

      post "/api/v1/security/two_factor/confirm",
        params: { code: "000000" }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to include("didn't work")
      expect(user.reload).not_to be_second_factor_enabled

      post "/api/v1/security/two_factor/confirm",
        params: { code: code_for(enrollment["secret"]) }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["two_factor"]).to include("enabled" => true, "recovery_codes_left" => RecoveryCode::COUNT)
      expect(json["recovery_codes"].length).to eq(RecoveryCode::COUNT)
      expect(user.reload).to be_second_factor_enabled
    end

    it "does not confirm an enrollment the client never started" do
      api_login(user)

      post "/api/v1/security/two_factor/confirm", params: { code: code_for(secret) }, headers: api_headers

      expect(response).to have_http_status(:gone)
      expect(user.reload).not_to be_second_factor_enabled
    end

    it "lets an abandoned enrollment expire" do
      enrollment = start_enrollment
      travel_to(2.hours.from_now) do
        post "/api/v1/security/two_factor/confirm",
          params: { code: code_for(enrollment["secret"]) }, headers: api_headers

        expect(response).to have_http_status(:gone)
      end
      expect(user.reload).not_to be_second_factor_enabled
    end
  end

  describe "turning it off" do
    before { enroll_over_api }

    it "costs the password, and takes the backup codes with the factor" do
      delete "/api/v1/security/two_factor", params: { password: "wrong" }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to include("Wrong password")
      expect(user.reload).to be_second_factor_enabled

      delete "/api/v1/security/two_factor", params: { password: "password123" }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["two_factor"]).to include("enabled" => false, "recovery_codes_left" => 0)
      user.reload
      expect(user).not_to be_second_factor_enabled
      expect(user.otp_secret).to be_nil
      expect(user.recovery_codes.count).to eq(0)
    end
  end

  describe "backup codes" do
    it "does not mint codes for an account with no second factor" do
      api_login(user)

      post "/api/v1/security/recovery_codes", params: { password: "password123" }, headers: api_headers

      expect(response).to have_http_status(:conflict)
      expect(user.recovery_codes.count).to eq(0)
    end

    it "replaces the set, and only the password authorises it" do
      old = enroll_over_api

      post "/api/v1/security/recovery_codes", params: { password: "nope" }, headers: api_headers
      expect(response).to have_http_status(:unprocessable_entity)

      post "/api/v1/security/recovery_codes", params: { password: "password123" }, headers: api_headers

      expect(response).to have_http_status(:ok)
      fresh = json.fetch("recovery_codes")
      expect(fresh).not_to include(*old)
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
      # What the row holds is a 64-hex digest, so the plaintext a client was
      # handed cannot be read back out of the database.
      expect(user.recovery_codes.pluck(:code_digest))
        .to all(match(/\A\h{64}\z/))
    end

    it "spends one at sign-in and refuses it twice" do
      codes = enroll_over_api

      post "/api/v1/sessions", params: { email: user.email, password: "password123", code: codes.first }

      expect(response).to have_http_status(:ok)
      expect(json.dig("two_factor", "recovery_codes_left")).to eq(RecoveryCode::COUNT - 1)
      expect(RecoveryCode.consume!(user.reload, codes.first)).to be_nil
    end
  end

  describe "phone verification" do
    it "asks for a number in international format" do
      api_login(user)

      post "/api/v1/security/phone", params: { phone: "0771234567" }, headers: api_headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["status"]).to eq("invalid_number")
    end

    it "issues a code, waits out the cooldown, then verifies the number" do
      api_login(user)
      post "/api/v1/security/phone", params: { phone: "+94771234567" }, headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["status"]).to eq("sent")
      # Local development driver only: there is no transport, so the session
      # that asked is the only place the code is ever shown.
      code = json.fetch("code")

      post "/api/v1/security/phone", params: { phone: "+94771234567" }, headers: api_headers
      expect(response).to have_http_status(:too_many_requests)
      expect(json["status"]).to eq("cooldown")
      expect(json["retry_in"]).to be_positive

      post "/api/v1/security/phone/confirm", params: { code: "000000" }, headers: api_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload).not_to be_phone_verified

      post "/api/v1/security/phone/confirm", params: { code: code }, headers: api_headers
      expect(response).to have_http_status(:ok)
      expect(json["phone"]).to include("verified" => true, "number" => "+94771234567")
      expect(user.reload).to be_phone_verified
    end
  end

  describe "devices" do
    it "revokes another device and keeps this one signed in" do
      api_login(user)
      other = AuthSession.start(user, user_agent: "dart:io (Shams mobile)", ip: "198.51.100.7")

      delete "/api/v1/security/devices/#{other.id}", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(other.reload).to be_revoked
      expect(json["devices"].map { |d| d["id"] }).not_to include(other.id)

      get "/api/v1/security"
      expect(response).to have_http_status(:ok)
    end

    it "does not know another account's device ids" do
      foreign_user = create(:user)
      foreign = AuthSession.start(foreign_user, user_agent: "dart:io", ip: "203.0.113.9")
      api_login(user)

      delete "/api/v1/security/devices/#{foreign.id}", headers: api_headers

      expect(response).to have_http_status(:not_found)
      expect(json["error"]).to include("not signed in")
      expect(foreign.reload.revoked_at).to be_nil
    end

    it "signs this client out when it revokes its own row" do
      api_login(user)
      mine = user.auth_sessions.active.first

      delete "/api/v1/security/devices/#{mine.id}", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["signed_out"]).to be(true)
      expect(mine.reload).to be_revoked
    end

    it "closes every session, including ones with no device row" do
      api_login(user)
      stale = AuthSession.start(user, user_agent: "dart:io", ip: "192.0.2.4")

      delete "/api/v1/security/devices", headers: api_headers

      expect(response).to have_http_status(:ok)
      expect(json["signed_out"]).to be(true)
      expect(user.reload.sessions_invalid_before).to be_within(1.minute).of(Time.current)
      expect(user.auth_sessions.active.count).to eq(0)

      get "/api/v1/security", headers: api_headers
      expect(response).to have_http_status(:unauthorized)
      expect(stale.reload).to be_revoked
    end
  end

  describe "what leaves the server" do
    it "hands the key out once, at the moment it is not yet the account's" do
      enrollment = start_enrollment
      post "/api/v1/security/two_factor/confirm",
        params: { code: code_for(enrollment["secret"]) }, headers: api_headers

      stored = user.reload.otp_secret
      expect(stored).to eq(enrollment["secret"])

      bodies = []
      get "/api/v1/security"
      bodies << response.body
      post "/api/v1/security/phone", params: { phone: "+94771234567" }, headers: api_headers
      bodies << response.body
      post "/api/v1/security/recovery_codes", params: { password: "password123" }, headers: api_headers
      bodies << response.body
      delete "/api/v1/security/devices/#{user.auth_sessions.active.first.id}", headers: api_headers
      bodies << response.body

      expect(bodies.join).not_to include(stored)
    end
  end

  private

  # The full path a client takes to a working second factor, returning the
  # backup codes it was shown once.
  def enroll_over_api
    enrollment = start_enrollment
    post "/api/v1/security/two_factor/confirm",
      params: { code: code_for(enrollment["secret"]) }, headers: api_headers
    json.fetch("recovery_codes")
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
