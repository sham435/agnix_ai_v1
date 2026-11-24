# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

# Two-factor (TOTP) sign-in. The password step and the code step are separate
# HTTP round-trips, and the only thing linking them is a session key that no
# other controller reads — so most of this file is about what a visitor is NOT
# allowed to do while that key is set.
RSpec.describe "Two-factor authentication", type: :request do
  let(:user) { create(:user) }
  let(:secret) { "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" }

  def enable_two_factor
    user.update!(otp_secret: secret, otp_enabled: true)
  end

  def code_for(known_secret = secret)
    ROTP::TOTP.new(known_secret).now
  end

  # Each page embeds a session-bound token, and signing in rotates the session,
  # so every step reads a fresh one off the page it is about to post to.
  def authenticity_token(path)
    get path
    response.body[/name="authenticity_token"[^>]*value="([^"]+)"/, 1]
  end

  def password_step(password: "password123")
    post "/login", params: { email: user.email, password: password,
                             authenticity_token: authenticity_token("/login") }
  end

  def code_step(code)
    post "/login/otp", params: { code: code, authenticity_token: authenticity_token("/login/otp") }
  end

  def signed_in?
    get settings_profile_path
    !response.redirect?
  end

  describe "password step" do
    it "signs straight through when two-factor is off" do
      password_step

      expect(response).to redirect_to(conversations_path)
      expect(signed_in?).to be(true)
    end

    it "keeps the welcome flash across the session reset" do
      password_step
      follow_redirect!

      expect(response.body).to include("Welcome back")
    end

    it "stops at the code step when two-factor is on" do
      enable_two_factor
      password_step

      expect(response).to redirect_to(login_otp_path)
      expect(signed_in?).to be(false)
    end

    it "still rejects a bad password without revealing the code step" do
      enable_two_factor
      password_step(password: "not-the-password")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Invalid email or password.")
      expect(signed_in?).to be(false)
    end
  end

  describe "code step" do
    before { enable_two_factor }

    it "refuses the page when nothing is pending" do
      get login_otp_path

      expect(response).to redirect_to(login_path)
    end

    it "signs in with the current code" do
      password_step
      code_step(code_for)

      expect(response).to redirect_to(conversations_path)
      expect(signed_in?).to be(true)
    end

    it "rejects a wrong code and lets the visitor retry" do
      password_step
      code_step("000000")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Try again")
      expect(signed_in?).to be(false)

      code_step(code_for)
      expect(response).to redirect_to(conversations_path)
    end

    it "drops the pending sign-in once the attempts run out" do
      password_step
      User::MAX_SECOND_FACTOR_ATTEMPTS.times { code_step("000000") }

      expect(response).to redirect_to(login_path)

      get login_otp_path
      expect(response).to redirect_to(login_path)
      expect(signed_in?).to be(false)
    end
  end

  describe "JSON API sign-in" do
    it "asks for a code and accepts it on retry" do
      enable_two_factor

      post "/api/v1/sessions", params: { email: user.email, password: "password123" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to include("two_factor_required" => true)
      expect(signed_in?).to be(false)

      post "/api/v1/sessions", params: { email: user.email, password: "password123", code: code_for }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("user", "email")).to eq(user.email)
      expect(JSON.parse(response.body).dig("two_factor", "enabled")).to be(true)
      expect(signed_in?).to be(true)
    end

    it "does not count the initial challenge as a failed code" do
      enable_two_factor

      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.otp_failed_attempts).to eq(0)
    end

    it "rejects a code without a browser-bound challenge" do
      enable_two_factor

      post "/api/v1/sessions", params: { email: user.email, password: "password123", code: code_for }

      expect(response).to have_http_status(:unauthorized)
      expect(signed_in?).to be(false)
    end

    it "rejects a challenge after five minutes" do
      enable_two_factor
      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      travel 6.minutes do
        post "/api/v1/sessions", params: { email: user.email, password: "password123", code: code_for }
        expect(response).to have_http_status(:unauthorized)
        expect(signed_in?).to be(false)
      end
    end

    it "does not transfer a challenge to another browser" do
      enable_two_factor
      post "/api/v1/sessions", params: { email: user.email, password: "password123" }
      other_browser = open_session

      other_browser.post "/api/v1/sessions",
        params: { email: user.email, password: "password123", code: code_for }

      expect(other_browser.response).to have_http_status(:unauthorized)
      expect(user.reload.otp_last_step).to be_nil
    end

    it "does not apply one account's challenge to another account" do
      enable_two_factor
      other_user = create(:user, otp_enabled: true, otp_secret: secret)
      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      post "/api/v1/sessions", params: { email: other_user.email, password: "password123", code: code_for }

      expect(response).to have_http_status(:unauthorized)
      expect(signed_in?).to be(false)
    end

    it "clears the previous browser identity while a challenge is pending" do
      previous_user = create(:user)
      api_login(previous_user)
      enable_two_factor

      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:unauthorized)
      expect(signed_in?).to be(false)
      expect(previous_user.auth_sessions.active.count).to eq(1)
    end

    it "calls a wrong code out as wrong, not as missing" do
      enable_two_factor
      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      post "/api/v1/sessions", params: { email: user.email, password: "password123", code: "000000" }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid two-factor code.")
      expect(signed_in?).to be(false)
    end

    it "reports two-factor as disabled for password-only accounts" do
      post "/api/v1/sessions", params: { email: user.email, password: "password123" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("two_factor", "enabled")).to be(false)
      expect(signed_in?).to be(true)
    end
  end

  describe "enrollment" do
    before { api_login(user) }

    def form_headers
      { "X-CSRF-Token" => api_headers["X-CSRF-Token"], "ACCEPT" => "text/html" }
    end

    it "stores nothing until the generated code is confirmed" do
      allow(TwoFactor).to receive(:generate_secret).and_return(secret)

      post settings_two_factor_path, headers: form_headers

      expect(response.body).to include("<svg")
      expect(response.body).to include(secret.scan(/.{1,4}/).join(" "))
      expect(user.reload.otp_enabled?).to be(false)

      post confirm_settings_two_factor_path, params: { code: "000000" }, headers: form_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.otp_enabled?).to be(false)

      post confirm_settings_two_factor_path, params: { code: code_for }, headers: form_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("backup codes")
      expect(user.reload.otp_secret).to eq(secret)
    end

    it "requires the password to turn two-factor back off" do
      enable_two_factor

      delete settings_two_factor_path, params: { password: "nope" }, headers: form_headers
      expect(response).to redirect_to(settings_two_factor_path)
      expect(user.reload.otp_enabled?).to be(true)

      delete settings_two_factor_path, params: { password: "password123" }, headers: form_headers
      expect(user.reload.otp_enabled?).to be(true)

      delete settings_two_factor_path, params: { password: "password123", code: code_for }, headers: form_headers
      expect(response).to redirect_to(settings_two_factor_path)
      expect(user.reload).not_to be_otp_enabled
      expect(user.otp_secret).to be_nil
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength
