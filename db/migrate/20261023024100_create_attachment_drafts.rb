# frozen_string_literal: true

# Item 4 of the Shams plan: server-backed attachment drafts. Uploads persist a
# draft row keyed by a client-held draft_token so a Turbo-refreshed composer
# can restore its chips without re-uploading bytes. Rows are consumed inside
# the message-save transaction and expire (lazy cleanup) so the table stays
# bounded.
class CreateAttachmentDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :attachment_drafts, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.string "draft_token", null: false
      t.uuid "asset_id", null: false
      t.string "label"
      t.datetime "expires_at", null: false
      t.timestamps

      t.index [ "user_id" ], name: "index_attachment_drafts_on_user_id"
      t.index [ "draft_token" ], name: "index_attachment_drafts_on_draft_token"
      t.index [ "expires_at" ], name: "index_attachment_drafts_on_expires_at"
      t.index [ "user_id", "draft_token", "asset_id" ], unique: true, name: "index_attachment_drafts_unique"
      t.foreign_key "users"
      t.foreign_key "assets"
    end
  end
end
