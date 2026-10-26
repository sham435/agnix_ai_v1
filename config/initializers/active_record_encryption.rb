# frozen_string_literal: true

require "openssl"
require "base64"

# Active Record attribute encryption (ToolIntegration#credentials) needs
# primary/deterministic keys, and this deployment carries no dedicated
# `active_record_encryption` credentials entry — without keys, ANY write to
# an encrypted attribute raises ActiveRecord::Encryption::Errors::Configuration
# (the marketplace connect flow would 500 on save).
#
# Derive stable keys from the app's own secret_key_base instead: it already
# exists per environment (generated in dev/test, credentials/ENV in prod), it
# is never committed, and rotating it rotates the encryption keys with it.
# If a real `active_record_encryption` credentials block is added later, its
# railtie-provided config runs before this initializer and this guard keeps
# the configured keys untouched.
unless ActiveRecord::Encryption.config.has_primary_key? || Rails.application.secret_key_base.blank?
  derive = lambda do |label|
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", Rails.application.secret_key_base, "shams:ar-encryption:#{label}"))
  end

  ActiveRecord::Encryption.configure(
    primary_key: derive.call("primary"),
    deterministic_key: derive.call("deterministic"),
    key_derivation_salt: derive.call("derivation"),
    salt: derive.call("salt")
  )
end
