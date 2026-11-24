# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers

# The account & security panel: every section it renders, and the enrollment
# order it exists to enforce — a secret stays in the session until a code
# proves the user can generate one, backup codes appear exactly once, and
# turning the protection off costs a fresh password and second-factor proof.
#
# Requests carry the Turbo-Frame header because that is what the panel sends;
# without it the controllers answer with redirects and the section ERB never
# runs, which is the half most likely to be broken. Every unsafe request takes
# its CSRF token off the section it was just rendered into, as a browser would.
RSpec.describe "Account panel", type: :request do
  let(:frame) { { "Turbo-Frame" => "account_panel_body" } }
  # The panel is the only place a pending secret or a dev-driver SMS code is
  # ever displayed, so the specs read them back off the page rather than
  # reaching into the session or the database row. The key is shown in 4-char
  # groups, exactly as the copy button hands it to a user.
  let(:dev_code) { /font-mono text-fg">(\d{6})</ }

  # Device labels are derived from the header, so the specs hand over headers a
  # real browser sends rather than the label they are expected to produce.
  let(:chrome_windows) do
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  end
  let(:firefox_linux) do
    "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
  end
  let(:safari_iphone) do
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " \
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  end

  let(:user) { create(:user) }
  let(:secret) { "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" }

  def token_in(body)
    body[/name="authenticity_token"[^>]*value="([^"]+)"/, 1]
  end

  # Rails mints a per-form CSRF token scoped to that form's own action, so the
  # token has to be read out of the very form the request imitates — a token
  # taken from a different form of the same page is refused, as it would be in
  # a browser.
  def token_for(action, body = response.body)
    pattern = %r{<form[^>]*action="#{Regexp.escape(action)}"[^>]*>.*?name="authenticity_token"[^>]*value="([^"]+)"}m
    body[pattern, 1]
  end

  # The page-wide token from `csrf_meta_tags`, which is good for any path. Only
  # needed to build a request no form could have produced — pointing at another
  # account's row — where what is under test is authorization, not forgery.
  def meta_token
    response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
  end

  def sign_in
    get login_path
    post "/login", params: { email: user.email, password: "password123",
                             authenticity_token: token_in(response.body) }
  end

  def open_panel(section)
    get account_panel_path(section: section), headers: frame
  end

  # The header's sign-out, which is the only way this app ends a browser
  # session that the panel itself does not offer a button for.
  def log_out
    get settings_profile_path
    delete logout_path, params: { authenticity_token: token_for("/logout") }
  end

  # Act on the panel the way the page does. The form is used where it already
  # is on screen (a section only draws the confirm form after enrollment, the
  # verify form after a code is sent); otherwise the section is opened first.
  # Destries go as POST + `_method`, which is what `button_to` sends.
  def panel_request(path, section, params = {})
    token = token_for(path)
    if token.nil?
      open_panel(section)
      token = token_for(path)
    end
    raise "the panel never rendered a form for #{path}" if token.nil?

    post path, params: params.merge(authenticity_token: token), headers: frame
  end

  def panel_destroy(path, section, params = {})
    panel_request path, section, params.merge(_method: "delete")
  end

  def code_for(known_secret = secret)
    ROTP::TOTP.new(known_secret).now
  end

  def enable_two_factor
    user.update!(otp_secret: secret, otp_enabled: true)
  end

  def start_enrollment
    panel_request account_two_factor_path, "two_factor"
  end

  def confirm_enrollment(code)
    panel_request account_confirm_two_factor_path, "two_factor", code: code
  end

  def pending_secret
    grouped = response.body[%r{<code class="block break-all[^>]*>\s*([^<]+?)\s*</code>}, 1]
    grouped.to_s.delete(" \n\t")
  end

  def disable_two_factor(password, code: nil)
    panel_destroy account_disable_two_factor_path, "two_factor", password: password, code: code
  end

  def regenerate_recovery_codes(password, code: nil)
    panel_request account_recovery_codes_path, "recovery", password: password, code: code
  end

  def send_phone_code(phone)
    panel_request account_phone_path, "phone", phone: phone
  end

  def confirm_phone_code(code)
    panel_request account_confirm_phone_path, "phone", code: code
  end

  def issued_phone_code
    response.body.match(dev_code)[1]
  end

  def revoke_device(id)
    panel_destroy account_device_path(id), "devices"
  end

  def close_everywhere
    panel_destroy account_devices_path, "devices"
  end

  # Signing in is the only way to get a session this controller can read, so a
  # second account's sign-out test has to go through the password step too.
  def sign_in_as(person)
    get login_path
    post "/login", params: { email: person.email, password: "password123",
                             authenticity_token: token_in(response.body) }
  end

  describe "sections" do
    before { sign_in }

    it "renders each of them for the signed-in user" do
      {
        "account"    => "Edit name, email and password",
        "security"   => "Authenticator app (TOTP)",
        "two_factor" => "Set up two-factor authentication",
        "phone"      => "Your mobile number",
        "devices"    => "This device",
        "usage"      => "Membership"
      }.each do |section, marker|
        open_panel(section)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(marker), "#{section} did not render #{marker}"
      end
    end

    it "falls back to the account section for a name it does not know" do
      open_panel("nope")
      expect(response.body).to include("Edit name, email and password")
    end

    it "answers the panel URL as a page when Turbo is not driving" do
      get account_panel_path(section: "security")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account settings")
    end

    it "reports the two-factor state on the security row" do
      enable_two_factor
      open_panel("security")
      expect(response.body).to include("Six-digit code required after your password")
    end
  end

  describe "access" do
    it "sends a visitor to sign in, from the frame and from the page" do
      open_panel("security")
      expect(response).to redirect_to(login_path)

      get account_panel_path(section: "security")
      expect(response).to redirect_to(login_path)
    end

    it "does not draw another account's devices" do
      other = create(:user)
      foreign = AuthSession.start(other, user_agent: firefox_linux, ip: "203.0.113.9")
      sign_in

      # This account's panel has no form pointing at that row, so the only token
      # that can be sent is the page-wide one. The forgery check passes and the
      # lookup is what refuses.
      get account_panel_path(section: "devices")
      post account_device_path(foreign.id),
           params: { authenticity_token: meta_token, _method: "delete" }, headers: frame

      expect(response.body).to include("not signed in")
      expect(foreign.reload.revoked_at).to be_nil
    end
  end

  describe "enrollment" do
    before { sign_in }

    it "stores nothing until the generated code is proved" do
      start_enrollment

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Scan this QR code with your authenticator")
      expect(user.reload).not_to be_second_factor_enabled
      expect(user.otp_secret).to be_nil
      expect(user.recovery_codes).to be_empty
    end

    it "rejects a wrong code and leaves the factor off" do
      start_enrollment
      confirm_enrollment("000000")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Check your app and try again")
      expect(user.reload).not_to be_second_factor_enabled
    end

    it "activates on a valid code and shows the backup codes once" do
      start_enrollment
      pending = pending_secret
      confirm_enrollment(code_for(pending))

      expect(response).to have_http_status(:ok)
      expect(user.reload).to be_second_factor_enabled
      expect(user.recovery_codes.count).to eq(RecoveryCode::COUNT)
      expect(response.body).to include("save them now")
    end

    it "spends the enrollment step before any sensitive change" do
      freeze_time do
        start_enrollment
        pending = pending_secret
        code = code_for(pending)
        confirm_enrollment(code)

        expect(user.reload.otp_last_step).to eq(Time.current.to_i / TwoFactor::STEP_SECONDS)
        disable_two_factor("password123", code: code)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(user.reload).to be_second_factor_enabled
      end
    end

    it "does not show the backup codes a second time" do
      start_enrollment
      confirm_enrollment(code_for(pending_secret))
      shown = response.body

      open_panel("recovery")
      expect(response.body).not_to include("Each code works once")
      expect(response.body).to include("left")
      expect(shown).to include("Each code works once")
    end

    it "expires a setup request that was left open" do
      start_enrollment
      pending = pending_secret

      travel_to(2.hours.from_now) { confirm_enrollment(code_for(pending)) }

      expect(response.body).to include("Start again")
      expect(user.reload).not_to be_second_factor_enabled
    end

    it "refuses to start a second enrollment over an active factor" do
      enable_two_factor
      start_enrollment

      expect(response.body).to include("already on")
      expect(user.reload.otp_secret).to eq(secret)
    end
  end

  describe "turning two-factor off" do
    # Sign in first: with the factor already on, the password step would stop
    # at the code challenge and the panel would never be reachable.
    before do
      sign_in
      enable_two_factor
      RecoveryCode.generate!(user)
    end

    it "requires the password and changes nothing without it" do
      disable_two_factor("wrong")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload).to be_second_factor_enabled
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
    end

    it "refuses a password without second-factor proof" do
      disable_two_factor("password123")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload).to be_second_factor_enabled
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
    end

    it "accepts a recovery code with the password" do
      code = RecoveryCode.generate!(user).first
      disable_two_factor("password123", code: code)

      expect(response).to have_http_status(:ok)
      expect(user.reload).not_to be_second_factor_enabled
      expect(user.recovery_codes).to be_empty
    end

    it "clears the secret and every backup code with the right password and authenticator proof" do
      disable_two_factor("password123", code: code_for)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user).not_to be_second_factor_enabled
      expect(user.otp_secret).to be_nil
      expect(user.recovery_codes).to be_empty
    end
  end

  describe "backup codes" do
    let!(:plaintext) { RecoveryCode.generate!(user) }

    before do
      sign_in
      enable_two_factor
    end

    it "mints a fresh set on request and retires the old ones" do
      old_code = plaintext.first

      regenerate_recovery_codes("password123", code: code_for)

      expect(response).to have_http_status(:ok)
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
      expect(RecoveryCode.consume!(user, old_code)).to be_nil
    end

    it "requires both the password and a second-factor proof to replace codes" do
      regenerate_recovery_codes("wrong", code: plaintext.first)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)

      regenerate_recovery_codes("password123")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
    end

    it "does not reuse regeneration's authenticator step to disable the factor" do
      freeze_time do
        code = code_for
        regenerate_recovery_codes("password123", code: code)
        expect(response).to have_http_status(:ok)

        disable_two_factor("password123", code: code)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(user.reload).to be_second_factor_enabled
      end
    end

    it "spends a code once and never twice" do
      code = plaintext.first
      expect(RecoveryCode.consume!(user, code)).to be_present
      expect(RecoveryCode.consume!(user, code)).to be_nil
    end

    it "refuses to hand out codes before the factor is on" do
      user.update!(otp_enabled: false)
      post account_recovery_codes_path, params: { password: "password123" }, headers: frame

      expect(response.body).to include("Set up two-factor first")
      expect(user.recovery_codes.unused.count).to eq(RecoveryCode::COUNT)
    end
  end

  describe "phone verification" do
    before do
      sign_in
      allow(PhoneVerification).to receive(:random_code).and_return("123456")
    end

    it "refuses a number it cannot place in E.164" do
      send_phone_code("12345")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("international format")
      expect(PhoneVerification.count).to eq(0)
    end

    it "issues a code and verifies the number with it" do
      send_phone_code("+94 77 123 4567")
      expect(response).to have_http_status(:ok)

      confirm_phone_code(issued_phone_code)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("+94771234567 is verified.")
      expect(response.body).not_to include("Not verified")
      user.reload
      expect(user.phone).to eq("+94771234567")
      expect(user).to be_phone_verified
    end

    it "does not spend a second code inside the cooldown" do
      send_phone_code("+94771234567")
      send_phone_code("+94771234567")

      expect(response).to have_http_status(:too_many_requests)
      expect(response.body).to include("Wait before asking for another code.")
      expect(user.phone_verifications.count).to eq(1)
    end

    it "keeps a wrong code away from the verified state" do
      send_phone_code("+94771234567")
      confirm_phone_code("000000")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload).not_to be_phone_verified
    end

    it "never accepts an SMS code as a second factor at sign-in" do
      send_phone_code("+94771234567")
      sms_code = issued_phone_code

      enable_two_factor
      log_out
      sign_in
      expect(response).to redirect_to(login_otp_path)

      get login_otp_path
      post "/login/otp", params: { code: sms_code, authenticity_token: token_for("/login/otp") }
      expect(response).to have_http_status(:unprocessable_entity)

      get settings_profile_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "signed-in devices" do
    before { sign_in }

    it "revokes a device that is not this one" do
      stale = AuthSession.start(user, user_agent: chrome_windows, ip: "198.51.100.4")

      revoke_device(stale.id)

      expect(response).to have_http_status(:ok)
      expect(stale.reload).to be_revoked
      expect(user.auth_sessions.active.count).to eq(1)
    end

    it "signs this request out when it revokes itself" do
      this_device = user.auth_sessions.active.first.id

      # The section labels this row and gives it no button, so the request is
      # sent with the page-wide token to cover the branch that still has to
      # behave: a revoke landing on the session serving it.
      get account_panel_path(section: "devices")
      post account_device_path(this_device),
           params: { authenticity_token: meta_token, _method: "delete" }, headers: frame

      expect(response).to redirect_to(login_path)
      get settings_profile_path
      expect(response).to redirect_to(login_path)
    end

    it "lists the device this request is using" do
      AuthSession.start(user, user_agent: chrome_windows, ip: "198.51.100.4")
      open_panel("devices")

      expect(response.body).to include("Chrome")
      expect(response.body).to include("This device")
    end
  end

  describe "signing out everywhere" do
    it "closes every session, including ones with no device row to revoke" do
      legacy = create(:user)
      AuthSession.start(legacy, user_agent: safari_iphone, ip: "192.0.2.10")
      sign_in_as(legacy)

      close_everywhere

      expect(response).to redirect_to(login_path)
      legacy.reload
      expect(legacy.sessions_invalid_before).to be_present
      expect(legacy.auth_sessions.active).to be_empty

      get settings_profile_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "what leaves the server" do
    before do
      sign_in
      enable_two_factor
      RecoveryCode.generate!(user)
    end

    it "never carries the stored secret" do
      AccountPanelResponses::SECTIONS.each do |section|
        open_panel(section)
        expect(response.body).not_to include(secret), "#{section} leaked the TOTP secret"
      end
    end

    it "never carries a backup code digest" do
      open_panel("recovery")
      user.recovery_codes.each do |row|
        expect(response.body).not_to include(row.code_digest)
      end
    end
  end
end

# rubocop:enable RSpec/MultipleExpectations, RSpec/ExampleLength, RSpec/MultipleMemoizedHelpers
