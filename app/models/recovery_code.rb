# Single-use backup codes for account recovery when the authenticator app is
# gone. 80 bits of randomness each, so a fast SHA-256 is enough — and the
# digest doubles as the lookup key, which is why the plaintext is never stored.
class RecoveryCode < ApplicationRecord
  belongs_to :user

  # Digits and letters that survive being read aloud or retyped from a
  # screenshot: no 0/O, 1/I/L.
  ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ".freeze
  LENGTH = 10
  COUNT = 10

  scope :unused, -> { where(consumed_at: nil) }

  class << self
    def generate!(user, count: COUNT)
      transaction do
        user.recovery_codes.unused.delete_all
        codes = Array.new(count) { random_code }
        codes.each { |code| create!(user: user, code_digest: digest(code)) }
        codes
      end
    end

    # Returns the code it consumed, or nil for anything that is not an unused
    # match. The update is a scoped one-row UPDATE rather than a read-then-save
    # so two requests racing on the same code cannot both spend it.
    def consume!(user, code)
      code = normalize(code)
      return nil if code.blank?

      row = user.recovery_codes.unused.find_by(code_digest: digest(code))
      return nil if row.nil?

      spent_at = Time.current
      return nil unless user.recovery_codes.unused.where(id: row.id)
        .update_all(consumed_at: spent_at) == 1

      # The write that spent it went through another object; this copy says the
      # same thing now, so a caller can trust `consumed?` on what it got back.
      row.consumed_at = spent_at
      row
    end

    def digest(code)
      Digest::SHA256.hexdigest(normalize(code))
    end

    def normalize(code)
      code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end

    def format(code)
      code.scan(/.{1,5}/).join("-")
    end

    private

    # 32 symbols divide 256 exactly, so mapping random bytes this way is
    # unbiased — and `rand` would not be cryptographically safe here.
    def random_code
      SecureRandom.bytes(LENGTH).bytes.map { |byte| ALPHABET[byte % ALPHABET.length] }.join
    end
  end

  def consumed?
    consumed_at.present?
  end
end
