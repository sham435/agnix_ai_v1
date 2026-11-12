# Everything the account panel needs in order to be redrawn — by the panel's
# own controllers after an action, or by its show route when a section is
# simply opened.
#
# The rule both halves follow: the panel is a turbo frame, so an action answers
# with the same frame instead of a page. A client without Turbo still gets a
# readable section, just as a redirect.
module AccountPanelResponses
  extend ActiveSupport::Concern

  SECTIONS = %w[account security two_factor recovery phone devices usage].freeze

  private

  def prepare_panel(section:, notice: nil, alert: nil, enrolling: false)
    @panel_section = SECTIONS.include?(section.to_s) ? section.to_s : "account"
    @panel_notice = notice
    @panel_alert = alert
    @two_factor_enrolling = enrolling
    # The pending key is only ever the half-finished enrollment, never the
    # stored one: an enabled secret is not shown to anyone, even its owner.
    @two_factor_pending = pending_two_factor if enrolling
    @recovery_codes_left = current_user.recovery_codes_remaining
    @two_factor_locked_minutes = current_user.two_factor_lock_minutes_left if @panel_section.in?(%w[security two_factor recovery])
    @organization = current_user.active_organization
    @active_devices = current_user.auth_sessions.active.count
    @devices = current_user.auth_sessions.visible if @panel_section == "devices"
    @phone_open = PhoneVerification.current_for(current_user) if @panel_section == "phone"
    @quota_summary = Quota.summary_for(current_user.active_organization) if @panel_section == "usage"
    @panel_section
  end

  def render_panel(section:, notice: nil, alert: nil, status: :ok, enrolling: false)
    prepared = prepare_panel(section: section, notice: notice, alert: alert, enrolling: enrolling)

    if turbo_frame_request?
      render "account/panels/show", layout: false, status: status
    else
      redirect_to account_panel_path(section: prepared), notice: notice, alert: alert
    end
  end

  def pending_two_factor
    TwoFactor.new(current_user, secret: session.dig(:otp_enrollment, "secret"))
  end
end
