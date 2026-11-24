# frozen_string_literal: true

require "rails_helper"

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers

# The account & security panel as a browser actually meets it: the slide-over
# opens over a live conversation, each section loads inside the turbo frame, and
# the enrollment order — pending secret, code, activation, backup codes shown
# once — is followed by clicking rather than by hand-built requests.
#
# Every example also writes a PNG under tmp/screenshots/account_panel, which is
# how the panel was reviewed by eye; the files are build output, not fixtures.
RSpec.describe "Account & security panel", :js, type: :system do
  let!(:user) { create(:user, name: "Panel Person") }
  let!(:organization) { create(:organization, owner: user, name: "Panel Works") }
  let!(:agent) { create(:agent, organization: organization) }
  let!(:conversation) do
    create(:conversation, user: user, agent: agent, title: "Quarterly report cleanup")
  end
  let(:phone) { "+94771234567" }
  let(:other_device) { AuthSession.start(user, user_agent: "Mozilla/5.0 (Windows NT 10.0)", ip: "203.0.113.9") }

  before do
    login_as user
    visit conversation_path(conversation)
  end

  it "slides open over the conversation and closes on Escape" do
    open_from_user_menu("Security & two-factor")

    expect(page).to have_css("#account-panel[data-open='true']")
    expect(panel_body).to have_text("Authenticator app (TOTP)")
    # The chat is still there, not replaced: the panel is a sheet, not a route.
    expect(page).to have_text("Quarterly report cleanup", wait: 1)
    expect(surface_width).to be_between(380, 420)

    snapshot("01-security")

    find("body").send_keys(:escape)
    expect(page).to have_css("#account-panel[data-open='false'][inert]")
  end

  it "closes when the backdrop is clicked" do
    open_from_user_menu("Account settings")
    expect(panel_body).to have_text("Edit name, email and password")

    find(".account-panel__backdrop").click

    expect(page).to have_css("#account-panel[data-open='false']", wait: 2)
  end

  it "walks the section tabs and reads each one's live state" do
    # The tabs that report on the account's organization need one to report on.
    create(:membership, user: user, organization: organization, role: "owner")
    open_from_user_menu("Security & two-factor")

    tab_to("Devices")
    expect(panel_body).to have_text("Sign out everywhere")
    expect(panel_body).to have_text("This device")
    snapshot("02-devices")

    tab_to("Usage")
    expect(panel_body).to have_text("Membership")
    expect(panel_body).to have_text("Panel Works")
    snapshot("03-usage")

    tab_to("Phone")
    expect(panel_body).to have_text("Your mobile number")
    expect(panel_body).to have_text("Not verified")
    snapshot("04-phone")

    tab_to("Account")
    expect(panel_body).to have_text(user.email)
    expect(panel_body).to have_text("Panel Works")
    snapshot("05-account")

    tab_to("Security")
    expect(panel_body).to have_text("Active sessions")
  end

  it "enrolls an authenticator with a real code and shows backup codes once" do
    open_from_user_menu("Security & two-factor")
    expect(panel_body).to have_text("Off — your password alone is enough to sign in.")

    click_on "Authenticator app (TOTP)"
    expect(panel_body).to have_text("Require a six-digit code from an authenticator app")
    snapshot("06-two-factor-off")

    click_button "Set up two-factor authentication"
    expect(panel_body).to have_text("Scan this QR code with your authenticator")
    expect(panel_body).to have_css("svg[role='img'][aria-label*='authenticator']")
    snapshot("06b-two-factor-enrolling")
    # Opening the screen is not turning anything on.
    expect(user.reload.second_factor_enabled?).to be(false)

    key = panel_body.find("code.block").text.split(" ").join
    # The compact fields carry an aria-label rather than a visible <label>, so
    # they are named here by the parameter they submit.
    fill_in "code", with: ROTP::TOTP.new(key).now
    click_button "Activate"

    expect(panel_body).to have_text("Save these codes now", wait: 5)
    expect(panel_body).to have_css("li", count: RecoveryCode::COUNT)
    snapshot("07-recovery-codes")
    expect(user.reload.second_factor_enabled?).to be(true)
    expect(user.otp_secret).to eq(key)

    # Shown once is the whole promise: the next render of the same section can
    # only count the codes, and the stored secret never reaches the page.
    tab_to("Security")
    click_on "Authenticator app (TOTP)"
    expect(panel_body).to have_text("The key itself is stored encrypted", wait: 5)
    expect(panel_body).not_to have_text(key)
    snapshot("08-two-factor-on")
  end

  it "verifies a phone number through the panel" do
    open_from_user_menu("Security & two-factor")
    click_on "Phone verification"

    fill_in "phone", with: phone
    click_button "Send code"

    expect(panel_body).to have_text("A code is waiting for this number")
    code = panel_body.find("code.font-mono").text
    snapshot("09-phone-code-sent")

    fill_in "code", with: code
    click_button "Verify"

    expect(panel_body).to have_text("#{phone} is verified.")
    expect(panel_body.find("a", text: "Phone verification")).to have_text("Verified")
    expect(user.reload.phone).to eq(phone)
    expect(user.phone_verified_at).to be_present
  end

  it "revokes another device and leaves this one signed in" do
    other_device
    open_from_user_menu("Security & two-factor")
    click_on "Active sessions"

    expect(panel_body).to have_text("Windows")
    within(panel_body) { click_button "Revoke" }

    expect(panel_body).to have_no_text("203.0.113.9")
    expect(panel_body).to have_text("This device")
    expect(other_device.reload.revoked?).to be(true)
    snapshot("10-devices-after-revoke")
  end

  it "turns two-factor off only for the right password and fresh authenticator proof" do
    secret = TwoFactor.generate_secret
    TwoFactor.activate!(user, secret)
    open_from_user_menu("Security & two-factor")

    click_on "Authenticator app (TOTP)"
    expect(panel_body).to have_text("Turn it off", wait: 5)

    fill_in "Current password", with: "not the password"
    fill_in "code", with: ROTP::TOTP.new(secret).now
    click_button "Disable two-factor"

    expect(panel_body).to have_text("Wrong password. Nothing was changed.")
    expect(user.reload.second_factor_enabled?).to be(true)

    fill_in "Current password", with: "password123"
    fill_in "code", with: ROTP::TOTP.new(secret).now
    click_button "Disable two-factor"

    expect(panel_body).to have_text("Two-factor authentication is off.")
    expect(user.reload.second_factor_enabled?).to be(false)
    expect(user.reload.otp_secret).to be_nil
    snapshot("11-two-factor-off")
  end

  it "becomes a full-height drawer on a phone-sized screen" do
    Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, 390, 844)

    # At this width the sidebar is off-canvas, so the chat header's avatar is
    # the only entry point — which is why the panel lives in the shell.
    open_from_user_menu("Security & two-factor")

    expect(panel_body).to have_text("Authenticator app (TOTP)")
    expect(surface_width).to be_within(2).of(390)
    snapshot("12-mobile-drawer")

    Capybara.page.driver.resize_window_to(Capybara.page.driver.current_window_handle, 1200, 800)
  end

  it "serves the same section without JavaScript as a page" do
    visit account_panel_path(section: "security")

    expect(page).to have_text("Authenticator app (TOTP)")
    expect(page).to have_text("Phone verification")
    snapshot("13-no-js-page")
  end

  private

  def panel_body
    find("#account_panel_body", wait: 10)
  end

  # The header avatar's menu is the entry point the brief asked for; the two
  # menus on a chat page share the one panel instance.
  def open_from_user_menu(item)
    find("header button[title^='Open user menu']").click
    within("header [data-dropdown-target='menu']") { click_link item }
    expect(page).to have_css("#account-panel[data-open='true']", wait: 5)
  end

  def tab_to(label)
    within("#account-panel nav[aria-label='Account sections']") { click_link label }
    expect(page).to have_css("#account-panel[data-open='true']", wait: 5)
  end

  def surface_width
    page.evaluate_script(
      "document.querySelector('#account-panel .account-panel__surface').getBoundingClientRect().width"
    )
  end

  def snapshot(name)
    directory = Rails.root.join("tmp/screenshots/account_panel")
    FileUtils.mkdir_p(directory)
    path = directory.join("#{name}.png")
    page.save_screenshot(path)
    expect(File.size(path)).to be > 5_000
    path
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/MultipleMemoizedHelpers
