# The account & security panel as data, for clients that cannot draw its turbo
# frames — the mobile app has the same screens to show. One shape for the whole
# panel, so an action answers with the state it just changed instead of making
# the client ask again.
#
# Nothing stored is a secret here: the two-factor key is never read back, and a
# pending enrollment key appears only in the response that minted it, which is
# the same rule the panel's own screens follow.
module ApiSecurityResponses
  extend ActiveSupport::Concern

  private

  def security_snapshot
    {
      two_factor: {
        enabled: current_user.second_factor_enabled?,
        recovery_codes_left: current_user.recovery_codes_remaining,
        locked_minutes_left: current_user.two_factor_lock_minutes_left
      },
      phone: {
        number: current_user.phone,
        verified: current_user.phone_verified?,
        verified_at: current_user.phone_verified_at
      },
      devices: security_devices,
      usage: security_usage
    }
  end

  def security_devices
    current_user.auth_sessions.visible.map do |device|
      {
        id: device.id,
        device: device.device,
        ip: device.ip,
        signed_in_at: device.created_at,
        last_seen_at: device.last_seen_at,
        current: Current.auth_session&.id == device.id
      }
    end
  end

  # `cap` and `remaining` are null for an unmetered plan. A client must read
  # that as "no daily ceiling", never as zero left.
  def security_usage
    summary = Quota.summary_for(current_user.active_organization)

    {
      organization: current_user.active_organization&.name,
      plan: summary.plan,
      metered: summary.metered?,
      cap: summary.cap,
      used: summary.used,
      remaining: summary.remaining
    }
  end
end
