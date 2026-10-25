# frozen_string_literal: true

# Phase 2 — Scheduled Tasks (ChatGPT Automations).
# Canonical automation records plus a per-execution run log. Results land in a
# conversation and surface on the /scheduled inbox. Scheduling math lives in the
# ScheduledTask model; these tables only persist the materialised next-fire UTC
# instant (next_run_at) that the TickJob polls.
class CreateScheduledTasksAndRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_tasks, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "user_id", null: false
      t.uuid "organization_id", null: false
      t.uuid "agent_id", null: false
      t.uuid "conversation_id"
      t.string "name", null: false
      t.text "prompt", null: false
      t.string "schedule_type", null: false
      t.string "cron"
      t.datetime "run_at", precision: nil
      t.string "timezone", null: false
      t.string "status", default: "active", null: false
      t.datetime "next_run_at", precision: nil
      t.datetime "last_run_at", precision: nil
      t.integer "run_count", default: 0, null: false
      t.integer "max_runs"
      t.datetime "expires_at", precision: nil
      t.jsonb "metadata", default: {}, null: false
      t.timestamps
      t.index ["user_id"], name: "index_scheduled_tasks_on_user_id"
      t.index ["organization_id"], name: "index_scheduled_tasks_on_organization_id"
      t.index ["agent_id"], name: "index_scheduled_tasks_on_agent_id"
      t.index ["conversation_id"], name: "index_scheduled_tasks_on_conversation_id"
      t.index ["status"], name: "index_scheduled_tasks_on_status"
      t.index ["next_run_at"], name: "index_scheduled_tasks_on_next_run_at"
      t.foreign_key "users", column: "user_id"
      t.foreign_key "organizations", column: "organization_id"
      t.foreign_key "agents", column: "agent_id"
      t.foreign_key "conversations", column: "conversation_id"
    end

    create_table :scheduled_task_runs, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.uuid "scheduled_task_id", null: false
      t.uuid "conversation_id"
      t.uuid "assistant_message_id"
      t.string "status", default: "queued", null: false
      t.datetime "started_at", precision: nil
      t.datetime "finished_at", precision: nil
      t.text "error"
      t.integer "tokens", default: 0, null: false
      t.timestamps
      t.index ["scheduled_task_id"], name: "index_scheduled_task_runs_on_scheduled_task_id"
      t.index ["conversation_id"], name: "index_scheduled_task_runs_on_conversation_id"
      t.index ["assistant_message_id"], name: "index_scheduled_task_runs_on_assistant_message_id"
      t.index ["status"], name: "index_scheduled_task_runs_on_status"
      t.foreign_key "scheduled_tasks", column: "scheduled_task_id"
      t.foreign_key "conversations", column: "conversation_id"
      t.foreign_key "messages", column: "assistant_message_id"
    end
  end
end
