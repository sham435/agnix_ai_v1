# A phone-ownership check: six digits sent to a number, valid for a few
# minutes. Deliberately its own table with its own rules — this proves someone
# controls a SIM, which is a different claim from the time-based code in
# TwoFactor, and the two are never interchangeable at sign-in.
class PhoneVerification < ApplicationRecord
  belongs_to :user, inverse_of: :phone_verifications

  IssueResult = Struct.new(:status, :row, :retry_in, keyword_init: true)

  CODE_LENGTH = 6
  TTL = 5.minutes
  # Six digits are 10^6 possibilities, so five guesses per number is the whole
  # budget before the row is dead.
  MAX_ATTEMPTS = 5
  # Re-asking for a code on every page refresh would burn the sending budget.
  RESEND_COOLDOWN = 45.seconds
  E164_FORMAT = /\A\+[1-9]\d{6,14}\z/

  # Outcomes of #verify, so callers never have to guess which string means what.
  VERIFIED = :verified
  INVALID = :invalid
  EXPIRED = :expired
  EXHAUSTED = :exhausted
  ALREADY_CONSUMED = :already_consumed

  scope :unconsumed, -> { where(consumed_at: nil) }
  scope :unexpired, -> { where("expires_at > ?", Time.current) }
  scope :open, -> { unconsumed.unexpired.order(created_at: :desc) }

  # Sending budget. Counted from the rows themselves rather than a cache, so
  # the limit is the same in every process and survives a restart.
  SEND_WINDOW = 1.hour
  MAX_SENDS_PER_WINDOW = 5

  class << self
    def in_window
      where(created_at: SEND_WINDOW.ago..)
    end

    def sent_by_user?(user)
      in_window.where(user_id: user.id).count >= MAX_SENDS_PER_WINDOW
    end

    def sent_to_phone?(phone)
      in_window.where(phone: phone).count >= MAX_SENDS_PER_WINDOW
    end

    def sent_from_ip?(ip)
      ip.present? && in_window.where(ip: ip).count >= MAX_SENDS_PER_WINDOW
    end
  end

  # The plaintext code, readable once straight after `.issue!` so the delivery
  # driver can send it. Nothing else ever exposes it, and it is never logged.
  attr_reader :code

  class << self
    # Every shared budget is locked in the same order across processes. The
    # insert commits before delivery, so a provider failure still spends a send.
    def issue_with_limits!(user, phone:, channel:, ip: nil)
      connection_pool.with_connection do |connection|
        transaction do
          keys = [ "user:#{user.id}", "phone:#{phone}" ]
          keys << "ip:#{ip}" if ip.present?
          keys.map { |key| Digest::SHA256.digest("phone-verification:send:#{key}").unpack1("q>") }.sort.each do |key|
            connection.execute("SELECT pg_advisory_xact_lock(#{key})")
          end

          if sent_by_user?(user) || sent_to_phone?(phone) || sent_from_ip?(ip)
            next IssueResult.new(status: :limited)
          end

          recent = where(user_id: user.id).or(where(phone: phone))
          recent = recent.or(where(ip: ip)) if ip.present?
          last_sent_at = recent.maximum(:created_at)
          if last_sent_at && last_sent_at > RESEND_COOLDOWN.ago
            retry_in = (last_sent_at + RESEND_COOLDOWN - Time.current).ceil.clamp(1, RESEND_COOLDOWN.to_i)
            next IssueResult.new(status: :cooldown, retry_in: retry_in)
          end

          next IssueResult.new(status: :unconfigured) if channel == "none"

          IssueResult.new(status: :sent, row: issue!(user, phone: phone, channel: channel, ip: ip))
        end
      end
    end

    def issue!(user, phone:, channel:, ip: nil, code: random_code)
      row = new(user: user, phone: phone, channel: channel, ip: ip,
        expires_at: Time.current + TTL)
      row.code = code
      row.save!
      row
    end

    # The newest row that has not already been spent, whatever its expiry says —
    # the caller needs it to answer "expired" instead of "no code was sent".
    def current_for(user)
      user.phone_verifications.unconsumed.order(created_at: :desc).first
    end

    # E.164, accepting the conventions people actually type: separators
    # anywhere, a `00` international prefix, or a `0`-led national number when
    # the deployment names its country. Anything ambiguous is rejected instead
    # of silently rewritten into somebody else's number.
    def normalize(raw)
      value = raw.to_s
      return nil unless /\A[0-9+() .\-]+\z/.match?(value)

      cleaned = value.delete("() .-")
      return nil if cleaned.blank?

      digits =
        if cleaned.start_with?("+")
          cleaned.slice(1..)
        elsif cleaned.start_with?("00")
          cleaned.delete_prefix("00")
        elsif cleaned.start_with?("0") && default_country_code.present?
          default_country_code + cleaned.delete_prefix("0")
        else
          return nil
        end

      candidate = "+#{digits}"
      candidate.presence if E164_FORMAT.match?(candidate)
    end

    def valid_number?(raw)
      normalize(raw).present?
    end

    # Set in the environment (e.g. "94") to allow national-format numbers.
    def default_country_code
      ENV["SHAMS_PHONE_COUNTRY_CODE"].to_s.gsub(/\D/, "")
    end

    def random_code
      format("%0#{CODE_LENGTH}d", SecureRandom.random_number(10**CODE_LENGTH))
    end
  end

  def expired?
    expires_at <= Time.current
  end

  def consumed?
    consumed_at.present?
  end

  def attempts_exhausted?
    attempts >= MAX_ATTEMPTS
  end

  def resend_allowed_at
    created_at + RESEND_COOLDOWN
  end

  def resend_blocked?
    created_at > RESEND_COOLDOWN.ago
  end

  def verify(input)
    # with_lock reloads stale instances and holds the row through the verdict,
    # attempt increment and ownership update. A code can succeed only once.
    with_lock do
      next ALREADY_CONSUMED if consumed?
      next EXPIRED if expired?
      next EXHAUSTED if attempts_exhausted?

      update!(attempts: attempts + 1)
      if matches?(input) && claim_phone
        VERIFIED
      else
        attempts_exhausted? ? EXHAUSTED : INVALID
      end
    end
  end

  def delivery_failed!
    # Keep the row for every send budget, but never accept an undelivered code.
    with_lock { update!(expires_at: Time.current) }
  end

  def code=(plaintext)
    @code = plaintext
    self.code_digest = BCrypt::Password.create(plaintext) if plaintext.present?
  end

  private

  def claim_phone
    # A savepoint keeps the spent attempt even if another account owns the
    # number (including a race caught by the unique index). Never move ownership.
    user.with_lock(requires_new: true) do
      user.update!(phone: phone, phone_verified_at: Time.current)
      update!(consumed_at: Time.current)
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.is_a?(User) && e.record.errors.of_kind?(:phone, :taken)

    false
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def matches?(input)
    digest = code_digest
    return false if digest.blank?
    return false unless input.is_a?(String) && /\A[0-9 -]+\z/.match?(input)

    normalized = input.delete(" -")
    return false unless /\A[0-9]{6}\z/.match?(normalized)

    # bcrypt compares in constant time relative to the input, which is the
    # point of storing these as password-style hashes rather than SHA-256.
    BCrypt::Password.new(digest) == normalized
  end
end
