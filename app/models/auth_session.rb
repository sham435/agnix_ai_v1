# One row per signed-in device. The browser holds a random token; this table
# only ever sees its SHA-256, so a read of the database cannot mint a session
# and a revoked row stops working on the next request, cookie or not.
class AuthSession < ApplicationRecord
  belongs_to :user

  # A row that has not been seen this long is not worth showing the user.
  STALE_AFTER = 30.days
  # `last_seen_at` is a convenience column, not a clock: writing it on every
  # request would turn every page into two writes.
  SEEN_WRITE_INTERVAL = 5.minutes

  scope :active, -> { where(revoked_at: nil) }
  scope :visible, -> { active.where(last_seen_at: STALE_AFTER.ago..).order(last_seen_at: :desc).limit(25) }

  # The raw token, readable once immediately after `.start` and never again.
  attr_accessor :token

  class << self
    def start(user, user_agent: nil, ip: nil)
      raw = SecureRandom.urlsafe_base64(24)
      session = create!(user: user, token_digest: digest(raw), device: describe(user_agent),
        ip: ip, last_seen_at: Time.current)
      session.token = raw
      session
    end

    def find_by_token(raw)
      return nil if raw.blank?

      find_by(token_digest: digest(raw))
    end

    def digest(raw)
      Digest::SHA256.hexdigest(raw.to_s)
    end

    # Every row except the one the caller is still using.
    def revoke_all_but(user, current_session)
      scope = user.auth_sessions.active
      scope = scope.where.not(id: current_session.id) if current_session
      scope.update_all(revoked_at: Time.current)
    end

    def prune!
      where.not(revoked_at: nil).where(last_seen_at: ...STALE_AFTER.ago).delete_all
    end

    # Browsers advertise themselves in a single header, so the whole label is
    # derived here rather than stored raw: less PII at rest and it re-renders
    # correctly if the wording changes later.
    def describe(user_agent)
      ua = user_agent.to_s
      return "Unknown device" if ua.blank?
      return "Shams mobile app" if ua.include?("dart:io")

      [ browser_for(ua), os_for(ua) ].compact.join(" · ").presence || "Unknown device"
    end

    private

    def browser_for(ua)
      case ua
      when /Edg\// then "Edge"
      when /OPR\/|Opera/ then "Opera"
      when /Firefox\// then "Firefox"
      when /Chrome\// then "Chrome"
      when /Safari\// then "Safari"
      end
    end

    def os_for(ua)
      case ua
      when /Windows/ then "Windows"
      when /iPhone|iPad|iOS/ then "iOS"
      when /Android/ then "Android"
      when /Mac OS X/ then "macOS"
      when /Linux/ then "Linux"
      end
    end
  end

  def revoked?
    revoked_at.present?
  end

  # Usable only if it was never revoked and, when the user pulled the global
  # "sign out everywhere" lever, it was issued after that moment.
  def usable_for?(user)
    return false if revoked?
    return true if user.sessions_invalid_before.blank?

    created_at > user.sessions_invalid_before
  end

  def touch_seen!
    return if last_seen_at.present? && last_seen_at > SEEN_WRITE_INTERVAL.ago

    now = Time.current
    update_columns(last_seen_at: now)
  end
end
