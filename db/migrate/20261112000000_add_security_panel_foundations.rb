# frozen_string_literal: true

# Security panel foundations.
#
# * users  — the state a second factor needs that a session cannot hold:
#            the last accepted TOTP step (replay guard), a failure counter that
#            survives "sign in again", and the timestamp that voids every
#            session older than it. `phone` / `phone_verified_at` record
#            ownership of a number, which is a different fact from 2FA.
# * recovery_codes — one row per single-use backup code, stored only as a
#            SHA-256 digest: they are 80-bit random, so a fast hash is safe and
#            the digest doubles as the lookup key.
# * auth_sessions — one row per signed-in device, keyed by the SHA-256 of the
#            token that lives in the browser. The token itself is never stored,
#            so a database leak cannot mint a session.
# * phone_verifications — SMS/WhatsApp OTP attempts. These are 6-digit and
#            guessable, so they get bcrypt (the same cost policy as passwords),
#            an expiry, an attempt count, and the sending context (ip) so the
#            hourly windows can be counted straight out of the table.
class AddSecurityPanelFoundations < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :otp_last_step, :integer
    add_column :users, :otp_failed_attempts, :integer, default: 0, null: false
    add_column :users, :otp_locked_until, :datetime
    add_column :users, :phone, :string
    add_column :users, :phone_verified_at, :datetime
    add_column :users, :sessions_invalid_before, :datetime
    add_index :users, :phone, unique: true, where: "(phone IS NOT NULL)", name: "index_users_on_phone"

    create_table :recovery_codes, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.string "code_digest", null: false
      t.datetime "consumed_at"
      t.datetime "created_at", null: false
      t.index [ "user_id", "code_digest" ], name: "index_recovery_codes_on_user_id_and_code_digest", unique: true
      t.index [ "user_id" ], name: "index_recovery_codes_on_user_id"
      t.foreign_key "users", column: "user_id"
    end

    create_table :auth_sessions, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.string "token_digest", null: false
      t.string "device"
      t.string "ip"
      t.datetime "last_seen_at", null: false
      t.datetime "revoked_at"
      t.datetime "created_at", null: false
      t.index [ "token_digest" ], name: "index_auth_sessions_on_token_digest", unique: true
      t.index [ "user_id", "last_seen_at" ], name: "index_auth_sessions_on_user_id_and_last_seen_at"
      t.foreign_key "users", column: "user_id"
    end

    create_table :phone_verifications, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.string "phone", null: false
      t.string "code_digest", null: false
      t.string "channel", default: "dev", null: false
      t.string "ip"
      t.datetime "expires_at", null: false
      t.integer "attempts", default: 0, null: false
      t.datetime "consumed_at"
      t.datetime "created_at", null: false
      t.index [ "user_id", "created_at" ], name: "index_phone_verifications_on_user_id_and_created_at"
      t.index [ "phone", "created_at" ], name: "index_phone_verifications_on_phone_and_created_at"
      t.index [ "ip", "created_at" ], name: "index_phone_verifications_on_ip_and_created_at"
      t.foreign_key "users", column: "user_id"
    end
  end
end
