# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_01_01_000019) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "agent_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "current_step"
    t.string "mode", default: "auto_plan", null: false
    t.jsonb "plan", default: [], null: false
    t.jsonb "reasoning_steps", default: []
    t.string "status", default: "planning", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "status"], name: "index_agent_runs_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_agent_runs_on_conversation_id"
  end

  create_table "agent_todos", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.text "result"
    t.string "status", default: "pending", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "position"], name: "index_agent_todos_on_agent_run_id_and_position"
    t.index ["agent_run_id"], name: "index_agent_todos_on_agent_run_id"
  end

  create_table "agents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "is_active", default: true, null: false
    t.string "model", default: "claude-sonnet-4-6", null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.string "provider", default: "anthropic", null: false
    t.integer "runs_count", default: 0, null: false
    t.string "slug", null: false
    t.text "system_prompt"
    t.jsonb "tools", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["is_active"], name: "index_agents_on_is_active"
    t.index ["organization_id", "slug"], name: "index_agents_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_agents_on_organization_id"
  end

  create_table "auto_fix_attempts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.jsonb "files_modified", default: []
    t.string "issue_id", null: false
    t.integer "iteration", null: false
    t.text "patch"
    t.string "status", null: false
    t.text "stderr"
    t.integer "tokens_used"
    t.datetime "updated_at", null: false
    t.index ["issue_id"], name: "index_auto_fix_attempts_on_issue_id"
  end

  create_table "conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.datetime "created_at", null: false
    t.integer "messages_count", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "mode", default: "", null: false
    t.uuid "project_id"
    t.string "status", default: "active", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agent_id"], name: "index_conversations_on_agent_id"
    t.index ["project_id"], name: "index_conversations_on_project_id"
    t.index ["status"], name: "index_conversations_on_status"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "invoices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "amount"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "hosted_invoice_url"
    t.string "invoice_pdf"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "organization_id", null: false
    t.datetime "paid_at"
    t.datetime "period_end"
    t.datetime "period_start"
    t.string "status", default: "draft", null: false
    t.string "stripe_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_invoices_on_organization_id"
    t.index ["stripe_id"], name: "index_invoices_on_stripe_id", unique: true
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "memories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.vector "embedding"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "source_id"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agent_id"], name: "index_memories_on_agent_id"
    t.index ["source_type", "source_id"], name: "index_memories_on_source_type_and_source_id"
    t.index ["user_id", "agent_id"], name: "index_memories_on_user_id_and_agent_id"
    t.index ["user_id"], name: "index_memories_on_user_id"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "delivery_status", default: "pending"
    t.string "external_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "read_at"
    t.string "role", null: false
    t.integer "tokens"
    t.jsonb "tool_calls", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["external_id"], name: "index_messages_on_external_id", where: "(external_id IS NOT NULL)"
    t.index ["role"], name: "index_messages_on_role"
  end

  create_table "organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "conversations_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "owner_id", null: false
    t.string "plan", default: "free", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_organizations_on_owner_id"
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "project_files", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "file_path"
    t.string "filename", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "project_id", null: false
    t.bigint "size", default: 0
    t.datetime "updated_at", null: false
    t.index ["project_id", "filename"], name: "index_project_files_on_project_id_and_filename", unique: true
    t.index ["project_id"], name: "index_project_files_on_project_id"
  end

  create_table "project_links", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "project_id", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["project_id"], name: "idx_project_links_on_project_id"
    t.index ["project_id"], name: "index_project_links_on_project_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.text "instructions"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.string "root_path"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agent_id"], name: "index_projects_on_agent_id"
    t.index ["organization_id", "name"], name: "index_projects_on_organization_id_and_name"
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.index ["user_id"], name: "idx_projects_on_user_id"
    t.index ["user_id"], name: "index_projects_on_user_id"
  end

  create_table "runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.jsonb "input", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "output"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.integer "tokens_used", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_runs_on_agent_id"
    t.index ["conversation_id"], name: "index_runs_on_conversation_id"
    t.index ["started_at"], name: "index_runs_on_started_at"
    t.index ["status"], name: "index_runs_on_status"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "cancel_at_period_end", default: false, null: false
    t.datetime "canceled_at"
    t.datetime "created_at", null: false
    t.datetime "current_period_end"
    t.datetime "current_period_start"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "organization_id", null: false
    t.string "status", default: "incomplete", null: false
    t.string "stripe_id", null: false
    t.string "stripe_price_id"
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_subscriptions_on_organization_id"
    t.index ["stripe_id"], name: "index_subscriptions_on_stripe_id", unique: true
  end

  create_table "tool_integrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "credentials", null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.uuid "organization_id", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["is_active"], name: "index_tool_integrations_on_is_active"
    t.index ["organization_id", "provider"], name: "index_tool_integrations_on_organization_id_and_provider"
    t.index ["organization_id"], name: "index_tool_integrations_on_organization_id"
  end

  create_table "usage_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "cost_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "organization_id", null: false
    t.uuid "run_id"
    t.integer "tokens", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_type"], name: "index_usage_events_on_event_type"
    t.index ["organization_id", "created_at"], name: "index_usage_events_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_usage_events_on_organization_id"
    t.index ["run_id"], name: "index_usage_events_on_run_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "last_login_at"
    t.string "name"
    t.string "password_digest", null: false
    t.string "remember_token"
    t.string "role", default: "user", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "stripe_customer_id"
    t.datetime "updated_at", null: false
    t.string "whatsapp_phone"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["remember_token"], name: "index_users_on_remember_token", unique: true
    t.index ["whatsapp_phone"], name: "index_users_on_whatsapp_phone", unique: true, where: "(whatsapp_phone IS NOT NULL)"
  end

  add_foreign_key "agent_runs", "conversations"
  add_foreign_key "agent_todos", "agent_runs"
  add_foreign_key "agents", "organizations"
  add_foreign_key "conversations", "agents"
  add_foreign_key "conversations", "projects"
  add_foreign_key "conversations", "users"
  add_foreign_key "invoices", "organizations"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "memories", "agents"
  add_foreign_key "memories", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "organizations", "users", column: "owner_id"
  add_foreign_key "project_files", "projects"
  add_foreign_key "project_links", "projects"
  add_foreign_key "projects", "agents"
  add_foreign_key "projects", "organizations"
  add_foreign_key "projects", "users"
  add_foreign_key "runs", "agents"
  add_foreign_key "runs", "conversations"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscriptions", "organizations"
  add_foreign_key "tool_integrations", "organizations"
  add_foreign_key "usage_events", "organizations"
  add_foreign_key "usage_events", "runs"
end
