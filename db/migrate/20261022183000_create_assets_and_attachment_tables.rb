# frozen_string_literal: true

# Phase 1 capability expansion: canonical asset storage, message-asset joins,
# library items pointing at assets (no duplicate bytes), and per-asset
# extraction records with processing states.
class CreateAssetsAndAttachmentTables < ActiveRecord::Migration[8.1]
  def change
    create_table :assets, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.uuid "project_id"
      t.string "filename", null: false
      t.string "content_type", null: false
      t.integer "byte_size", null: false
      t.string "checksum", null: false
      t.string "status", default: "ready", null: false
      t.jsonb "metadata", default: {}, null: false
      t.timestamps
      t.index ["user_id"], name: "index_assets_on_user_id"
      t.index ["project_id"], name: "index_assets_on_project_id"
      t.index ["status"], name: "index_assets_on_status"
      t.index ["user_id", "checksum"], unique: true, name: "index_assets_on_user_id_and_checksum"
      t.foreign_key "users", column: "user_id"
      t.foreign_key "projects"
    end

    create_table :message_attachments, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "message_id", null: false
      t.uuid "asset_id", null: false
      t.timestamps
      t.index ["message_id"], name: "index_message_attachments_on_message_id"
      t.index ["asset_id"], name: "index_message_attachments_on_asset_id"
      t.index ["message_id", "asset_id"], unique: true, name: "index_message_attachments_unique"
      t.foreign_key "messages"
      t.foreign_key "assets"
    end

    create_table :library_items, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.uuid "asset_id", null: false
      t.string "label"
      t.timestamps
      t.index ["user_id"], name: "index_library_items_on_user_id"
      t.index ["asset_id"], name: "index_library_items_on_asset_id"
      t.index ["user_id", "asset_id"], unique: true, name: "index_library_items_unique"
      t.foreign_key "users"
      t.foreign_key "assets"
    end

    create_table :asset_extractions, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "asset_id", null: false
      t.string "status", default: "pending", null: false
      t.string "error_code"
      t.text "content"
      t.jsonb "meta", default: {}, null: false
      t.timestamps
      t.index ["asset_id"], name: "index_asset_extractions_on_asset_id"
      t.index ["status"], name: "index_asset_extractions_on_status"
      t.unique_constraint "asset_id"
      t.foreign_key "assets"
    end

    # Conversations may be attached to a project for project-scoped context.
    # (conversations.project_id column + index already exist in schema.)
    add_foreign_key :conversations, :projects unless foreign_key_exists?(:conversations, :projects)
  end
end
