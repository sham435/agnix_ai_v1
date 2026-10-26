# frozen_string_literal: true

# Phase 3 — Image Generation (ChatGPT-style image gallery).
# One row per generation request: the user-facing record is canonical, bytes
# become a normal Asset through the existing ingest pipeline (asset_id link).
# `metadata` carries provider-side detail (revised_prompt, provider image ids)
# plus chat linkage (conversation_id) so in-flight gating can scope by
# conversation without widening the schema.
class CreateImageGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :image_generations, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.uuid "organization_id"
      t.text "prompt", null: false
      t.string "provider", default: "openai", null: false
      t.string "model", default: "gpt-image-1", null: false
      t.string "size", default: "1024x1024", null: false
      t.string "quality", default: "auto", null: false
      t.integer "n", default: 1, null: false
      t.string "status", default: "queued", null: false
      t.text "error"
      t.uuid "asset_id"
      t.jsonb "metadata", default: "{}", null: false
      t.timestamps
      t.index ["user_id"], name: "index_image_generations_on_user_id"
      t.index ["organization_id"], name: "index_image_generations_on_organization_id"
      t.index ["asset_id"], name: "index_image_generations_on_asset_id"
      t.index ["status"], name: "index_image_generations_on_status"
      t.index ["created_at"], name: "index_image_generations_on_created_at"
      t.foreign_key "users", column: "user_id"
      t.foreign_key "organizations", column: "organization_id"
      t.foreign_key "assets", column: "asset_id"
    end
  end
end
