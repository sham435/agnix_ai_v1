# Shams AI — Milestones & TODO

Updated: 2026-11-24 · Branch `main` · Verification base `a7df7f5` · Public beta LIVE (rotating TryCloudflare URL) · **Not release-ready** — security blockers and deployment gates remain open.

Status legend: ✅ achieved & verified · 🟡 achieved in tree, not yet deployed or independently accepted · ⛔ pending or blocked.

---

## Achieved milestones

### 1. Core platform — organizations, conversations, JSON API ✅
Rails 8.1 app with members area, org CRUD, settings/integration-key pages, agent conversations/runs/playground, memories, profile routes, and the v1 JSON API consumed by web and mobile.
Evidence: `34b1081`, `df4388a`, `7c6f0c5`, `7ea5dd6`.

### 2. Provider hardening and honest failure handling ✅
Provider calls hardened; run completion gated on real outputs; Anthropic failures classified into typed error codes with retry only on recoverable causes; typed cause surfaced through runner and job; retry path coverage closed.
Evidence: `7f92bf6`, `120cb53`, `27f0e07`, `b479ede`, `d1f3ca6`.

### 3. Streaming reliability and run integrity ✅
Streamed partials kept when a run is cut off; per-turn output budgets with honest truncation detection; re-delivered builds resume by skipping completed writes; Timeout no longer kills runs or fabricates failures; Regenerate no longer deletes answers it cannot replace; request idempotency preserved.
Evidence: `5092c04`, `ac6a18d`, `7f7131a`, `e19b106`, `f3de1b9`, `34def39`, `dd25e23`.

### 4. Flutter client — macOS, Windows, Android ✅
Flutter client shipped for three platforms with CI artifact builds (macOS/Windows runners, archive verification); CocoaPods integrated, macOS floor 12.0; macOS release app built, launched and tested end-to-end; live Markdown streaming with timings; failed-turn explanations; 2FA sign-in and security screen.
Evidence: `20063c6`, `64cc230`, `f5dd78e`, `46bfc44`, `130f619`, `b44122e`, `7925e11`, `5530682`.

### 5. Local Bonsai 27B routing ✅
Local-model turns serialized with host-resource sampling; chain-of-thought kept out of answers; quoted stream failures kept on one line; streamed turns judged by HTTP status. Bonsai stays host-only on 127.0.0.1:8080.
Evidence: `5a951b4`, `0d68e4d`, `9a18d6e`, `4bceda9`, `5b0a7fd`, `867a734`.

### 6. Agent tooling — scaffolding and OS execution ✅
Verified single-call project scaffolding (Django acceptance), scaffolding enabled in chat with idempotent grants, OS execution with pinned workspace specs, raised tool-loop budgets (20 conversational, larger for build/OS runs), bounded tool transcript per iteration.
Evidence: `07b5ff3`, `ffbbafb`, `d46fcde`, `4f06977`, `9f1ed67`, `f7d77ae`, `3d4052d`.

### 7. Private production hosting (Phase 0/1 + Apache loopback) ✅
Zero-cost Mac hosting live since 2026-11-11: Cloudflare edge TLS → cloudflared → loopback Apache :80 → Dockerized public Rails `shams-public` (web/jobs/db, pgvector pg18) on 127.0.0.1:3002; dev untouched on :3001. Full HTTPS flow verified including chat and Cable. Config backups taken before edits; 5432 unpublished.
Evidence: `f7922e5`; Apache config at `/opt/homebrew/etc/httpd/` with pre-edit backup `~/Backups/apache-20261111-010352/`.

### 8. M13 — supervised public tunnel ✅
Quick tunnel under LaunchAgent `com.shams.public.tunnel` → `deploy/tunnel_keeper.sh`: restarts cloudflared, publishes the live hostname to `~/.config/shams/tunnel_url`, rewrites `APP_HOST` and recreates web+jobs on hostname change; detects Cloudflare route revocation (NXDOMAIN behind a live process) and revives it. Verified live 2026-11-12: forced restart → new hostname → `/login` 200.
Evidence: `b942834`, `a7df7f5`.

### 9. Two-factor authentication + account & security panel 🟡
Real TOTP (rotp/rqrcode), optional 2FA sign-in gated on web and API, recovery codes, auth-session tracking, phone-verification data layer, enrollment UI and right-side security panel, Flutter 2FA flow; specs/RuboCop/Brakeman run. **Committed (`0a9af29`, `d2884f3`) but NOT deployed** — public `/account` 404s until the Docker stack is rebuilt + migrated (deployment gated).

### 10. Demo-readiness fixes (Phase 8/9 items) 🟡
Dead header avatar fixed; per-organization daily token quota ledger (`Quota`/`UsageEvent`); responsive Stop button; `Organization#plan` self-edit hole closed. **Implementation verified in tree; deployment remains gated.**

### 11. Docker-backed contextual workspaces (M11) 🟡
Docker workspace manager with ownership models, WorkspaceProvider (12 operations), ten registered agent tools, authenticated preview gateway, web panel and Flutter screen; the earlier real Flask end-to-end acceptance and fixed-image daemon verification remain valid historical evidence. Subsequent manager hardening now bounds subprocess stdout/stderr, file reads and ZIP export buffering, disables preview redirect following, and makes absent-resource destruction idempotent; those changes pass Docker-free manager and Rails request tests, but real Flask/Docker re-acceptance is still gated. Chat context remains preserved across modes with truthful provider readiness.

### 12. M14 — dynamic model selection, Issues A & B 🟡
Verified at implementation level; not deployed:
- **Issue A — selection precedence:** acceptance spec proves the ladder conversation → organization-scoped user preference → organization default → permitted system fallback → clear `model_required` error; an absent conversation selection never bypasses the user preference; effective model captured on the source message at enqueue so later config changes cannot alter an in-flight request.
- **Issue B — honest provider readiness:** four-state ladder (Connected / Catalogue available / Inference ready / Billing blocked) computed from real inference outcomes recorded on the connection via `update_columns` (no catalogue-cache busting); per-model `verified` only for the model that actually served a success; rendered in settings view, web selector and Flutter sheet. An out-of-credit Anthropic key renders as **Billing blocked**, never as usable.
- Verification: precedence 6/6; targeted Rails batches 178/178 and 79/79 (0 failures); system specs 11/11; Flutter 107/107; `flutter analyze` clean; RuboCop clean on all 8 touched files.

### 13. M14 — read-only disk audit ✅
Full audit with exact candidate paths/sizes (Docker.raw 8.0G allocated, 13 dead volumes ~3.4GiB, build cache 1.9GB, gradle 5.2G, pnpm 5.9G, brew 3.3GB, rotated logs 200M, Flutter build 1.1G). Brew cleanup manifest recorded: `/tmp/m14-brew-cleanup-manifest.txt` (37 targets, ~3.3GB, all old formula versions). No deletion performed.

### 14. M15-A — public beta isolation audit (read-only) ✅ AUDIT COMPLETE — M15 implementation NOT achieved
Four parallel read-only audit agents + main-agent source verification of every critical/high claim (2026-11-20). Report (outside the git tree): `/Users/sham4/bonsai227b-shamsai/m15a-beta-isolation-audit.md`. Working tree verified untouched: 142 paths, 0 staged, 0 stashes. **Verdict: an untrusted beta user CANNOT safely be invited today.**
- **CRITICAL (verified):** C1 IDOR `users_controller.rb:22` — any signed-in user reads any account's email/conversations/memories and can rewrite the admin's email; C2 free tier unmetered (`quota.rb:13`) + zero rate limiting = unlimited inference per invited account; C3 real OpenRouter-format key in `log/development.log` (21 lines, count-verified, never printed) + 187 gateway requests logged with full prompt parameters → **key rotation + log purge needed (user action)**.
- **HIGH (verified):** H1 any org member reads/overwrites provider keys via marketplace controller (no role gate) + plaintext key prefilled in edit/connect form HTML; H2 unsigned publicly reachable WhatsApp webhook (live probe: verify endpoint reachable) + global cross-tenant `Agent.first` binding; H3 org-wide run input/output disclosure; H4 admin→owner self-escalation / owner eviction / consentless adds; H5 non-atomic `Quota.reserve` (comment claims atomicity — false); H6 gateway has no quota/validation at Rails layer (Apache 403 is the only containment); H7 no login throttle; H8 no per-org concurrent-run cap.
- **MEDIUM:** Cable ignores device revocation (amplified by prod/dev shared `SECRET_KEY_BASE`); admin `settings:{}` mass assignment bypasses owner-only model gates; ENV/credentials key fallback usable by any org; log filters miss `:email/:code/:session` (plaintext TOTP/recovery codes + preview tokens in logs); Solid Queue re-delivery double-charges; unbounded indexes; error leakage; jobs trust serialized ids.
- **Verified sound:** conversation/asset/workspace/memory per-user scoping, org-keyed honest quota accounting, encrypted credentials + owner-only settings surface, workspace/Docker boundary (63/63), Stripe signature verification, plan immutability, signup closed, P0 Gate A containment.
- 14 missing acceptance tests + 12-step M15 implementation order in report §5–§6. **No fix implemented; every remediation gated on separate approval.**

### 15. P0 — OpenAI-compatible gateway security (Gate A ✅ contained · Gate B ⛔ deploy outstanding)
`/api/v1/openai/*` was publicly reachable with no auth, proxying anonymous callers to the host Bonsai 27B (`host.docker.internal:8080`). Verified live 2026-11-20: unauthenticated `GET models` → 200; malformed POST reached the controller action (no 401). No legitimate dependents found (OpenCode talks to llama.cpp :8080 directly).
- **Done in tree:** controller now `< ApplicationController` + `authenticate_user!` — same session/CSRF policy as every other API v1 endpoint; proxy contract and streaming untouched. New request specs **4/4** (401 without session, zero upstream provider calls proven via WebMock, signed-in proxy intact, unrelated endpoints unaffected); targeted regression **179/179**; RuboCop clean.
- **Gate A — public exposure containment: ✅ ACHIEVED, live-verified 2026-11-20.** Apache rule applied (`ProxyPass /api/v1/openai/ !` + `LocationMatch "^/api/v1/openai(/|$)" Require all denied`); configtest `Syntax OK`; user-executed sudo graceful reload. Live public verification: gateway GET models → **403**, gateway POST completions → **403** (Apache Forbidden, never proxied); `/login` → **200**; `/api/v1/csrf` → **200**; `/api/v1/capabilities` → **401 Rails JSON**; `/api/v1/models` → **404 from Rails** (proxy intact); `/cable` WebSocket upgrade → **101 Switching Protocols**. Backup: `~/Backups/apache-p0-20261120-084358/`. Note: the first staged diff mislabeled its `+++` target; regenerated with explicit labels, dry-run verified before apply.
- **Gate B — Rails authentication fix deployed: ⛔ OUTSTANDING.** Containment ≠ deployment: the public Docker image still runs the unauthenticated controller (blocked at Apache). The fix ships with the next approved Docker rebuild; loopback :3002 keeps the old behavior until then.

### 16. Multi-provider inference + NVIDIA NIM 🟡
Implemented in tree without a schema migration. Built-in OpenRouter, Groq, Google AI Studio/Gemini, Cerebras and NVIDIA NIM use the existing encrypted `ToolIntegration` credential boundary; organizations can also register bounded OpenAI-compatible endpoints. Model records carry API family, capability flags, limits/options, rate/discovery metadata and verification state. Catalogue discovery never marks a model inference-ready: only a non-empty real completion or a tool-call-only completion verifies the exact canonical model and credential/transport fingerprint. Empty/reasoning-only responses, missing credentials and current authentication failures cannot inherit stale success.

Provider transport now enforces HTTPS for remote endpoints, production private/loopback/metadata/reserved-address rejection (with the existing trusted-local Bonsai/Ollama exception), DNS validation and address pinning for custom hosts, disabled redirects, CRLF-safe allowlisted headers, bounded request/response/SSE sizes, configurable timeouts and bounded retries. Typed provider errors and `Retry-After` handling are shared by Chat Completions and Responses adapters. Bonsai routing and its canonical `ENV["BONSAI_MODEL"]` inference identity are preserved.

NVIDIA NIM is `nvidia_nim` / `NVIDIA NIM`, base URL `https://integrate.api.nvidia.com/v1`, default `chat_completions`, endpoint `/v1/chat/completions`, encrypted Bearer key, blank-key preservation and manual-only discovery. Its four example IDs are catalogue examples, not guarantees of account access or inferred capabilities: `nvidia/nemotron-3.5-lightning-30b-a3b`, `nvidia/nemotron-3.5-bolt-e4b`, `deepseek-ai/deepseek-v4-flash`, `meta/llama-3.3-70b-instruct`. Saving or discovery makes no billable inference request.

Key files: `app/services/llm/provider_registry.rb`, `provider_connection.rb`, `provider_endpoint.rb`, `provider_error.rb`, `secure_http.rb`, `provider_settings.rb`, `model_catalogue.rb`, `model_selection.rb`, `inference_tracker.rb`, `client.rb`, `openai_adapter.rb`, `responses_adapter.rb`, `agent_runner.rb`; `app/controllers/api/v1/models_controller.rb`, `settings/integrations_controller.rb`; `app/views/settings/integrations/index.html.erb`; `app/javascript/controllers/model_selector_controller.js`; Flutter `apps/shams/lib/src/widgets/model_selector.dart`; provider/model specs under `spec/services/llm/`, `spec/requests/settings_provider_architecture_spec.rb`, `spec/requests/api/v1/models_spec.rb`, `spec/system/model_selector_spec.rb`, `spec/services/llm/nvidia_nim_spec.rb`.

### 17. M18 — composer, queue, steering, task status and workspace actions 🟡
The Mac Enter bug was traced to native form submission plus platform-insensitive key handling before any queue was added. Enter sends when idle; Shift+Enter inserts a newline; Cmd/Ctrl+Enter sends when idle and steers an active run; Enter queues a follow-up while running; IME composition does not submit. Submission snapshots preserve newer drafts and attachments, and client request IDs make browser/API/Action Cable admission idempotent.

The schema-free implementation reuses `Conversation.metadata`, row locks, `AgentStreamJob`, existing Cable/Turbo frames and `client_request_id`. `Conversations::TurnAdmission` is the shared admission path. One assistant placeholder claims the live turn before enqueue; FIFO follow-ups and steering are bounded, persisted across navigation/reconnection and dispatched only at safe runner boundaries. Stop/regenerate cannot bypass active `Run`/`AgentRun` claims; Stop hands off to the next queued item exactly once. Task counts and task details come from authoritative server snapshots (`Run` and manual-plan `AgentRun` included), not a client elapsed-time guess. Workspace quick actions open the existing side-task, terminal, preview/browser and files surfaces without creating a run or executing a command; hover, click/touch-style activation, Escape, Arrow keys and Enter are covered in Cuprite.

Key files: `app/services/conversations/turn_admission.rb`, `app/jobs/agent_stream_job.rb`, `app/services/agent_runner.rb`, `app/services/conversations/regenerate_chat.rb`, `app/controllers/messages_controller.rb`, `app/controllers/api/v1/messages_controller.rb`, `app/controllers/conversations_controller.rb`, `app/channels/conversation_channel.rb`, `app/javascript/controllers/chat_input_controller.js`, `chat_controller.js`, `dropdown_controller.js`, `workspace_panel_controller.js`, `app/views/messages/_form.html.erb`, `create.turbo_stream.erb`, `app/views/conversations/show.html.erb`; specs `spec/services/conversations/turn_admission_spec.rb`, `spec/requests/conversation_tasks_spec.rb`, `spec/requests/messages_spec.rb`, `spec/requests/message_idempotency_spec.rb`, `spec/requests/message_attachments_spec.rb`, `spec/requests/message_tools_selection_spec.rb`, `spec/requests/conversation_stop_spec.rb`, `spec/requests/regenerate_spec.rb`, `spec/jobs/agent_stream_job_spec.rb`, `spec/system/composer_spec.rb`, `spec/system/in_flight_guard_spec.rb`, `spec/system/stalled_run_live_recovery_spec.rb`.

### 18. Real `%webfetch` and model-callable `webfetch` 🟡
`WebfetchService` performs bounded HTTP/HTTPS retrieval with SSRF/DNS/redirect/timeout/size protections and request-scoped proxy bypass. HTML is extracted to Markdown/plain text/HTML; JSON and XML remain bounded textual content. `WebfetchCommand` parses explicit `%webfetch URL`, replays idempotently by request/source identity, and stores a bounded digest-keyed marker map. `AgentStreamJob` handles the explicit command before quota/provider dispatch; automatic calls use the same service through the native capability registry. Authorization and conversation/agent ownership are checked before argument handling, DNS or HTTP. Fetched content is explicitly marked untrusted, and the active Shams AI tool definitions include `webfetch` with required `url`, `format` (`markdown|text|html`) and `timeout` (1–120 seconds).

Key files: `app/services/webfetch_service.rb`, `webfetch_command.rb`, `app/services/agents/tool_registry.rb`, `app/services/capabilities/registry.rb`, `app/services/tools/catalog.rb`, `app/jobs/agent_stream_job.rb`, `app/controllers/agents/conversations_controller.rb`, `app/services/whatsapp_service.rb`; specs `spec/services/webfetch_service_spec.rb`, `spec/services/webfetch_integration_spec.rb`, `spec/jobs/agent_stream_job_webfetch_spec.rb`, `spec/services/agents/tool_registry_spec.rb`.

### 19. Tavily, Deep Research, Figma and Image Generation activation 🟡
Tavily search is a real bounded adapter returning source URLs/titles/snippets. Deep Research performs multiple real searches with source/call/time/question budgets, canonical-URL deduplication, a source ledger and snippet-only findings; it does not pretend to have reviewed full pages or synthesized unsupported claims. Model-facing research output is compact and byte-bounded, while the runner persists the full service result and consolidated ledger in assistant metadata; final answers receive a deterministic numbered source appendix and unsupported Markdown/bare-URL citations are replaced with explicit markers. Oversized tool results remain valid UTF-8-safe JSON. Figma remains an authorized read-only file fetch. OpenAI Images generation uses the existing key/readiness path, avoids automatic retries of potentially charged POSTs, persists results as assets and surfaces them in the conversation/gallery. Capability availability is computed backend-side; native tools enforce capability state and organization authorization before execution.

Key files: `app/services/integrations/web_search.rb`, `bounded_json_request.rb`, `figma_get_file.rb`, `app/services/research/deep_research.rb`, `app/services/images/generator.rb`, `app/jobs/images/generate_job.rb`, `app/models/image_generation.rb`, `app/services/capabilities/registry.rb`, `app/services/agents/tool_registry.rb`, `app/controllers/images_controller.rb`; specs `spec/services/integrations/search_and_figma_spec.rb`, `spec/services/research/deep_research_spec.rb`, `spec/services/images/generator_spec.rb`, `spec/jobs/images/generate_job_spec.rb`, `spec/models/image_generation_spec.rb`, `spec/requests/images_gallery_spec.rb`, `spec/system/images_navigation_spec.rb`.

### 20. Concrete navigation/regeneration fixes 🟡
`ImagesController#regenerate` now normalizes legacy string metadata before removing provider-only fields, fixing `undefined method 'except' for an instance of String`. `resources :agents` includes `:index`, fixing GET `/agents`. Focused request/system regressions cover both paths.

### 21. Final-review remediation and verification 🟡
The final review dependencies were fixed without a schema migration: WhatsApp replies now resolve the exact organization integration that received the inbound message and never fall back to global credentials; workspace-manager subprocess pipes, container file reads and ZIP exports are bounded while excess output is still drained; preview bodies are capped before buffering and external/control-character/backslash redirects are rejected; absent workspace containers/volumes destroy idempotently; image redelivery cannot automatically repeat a possibly charged provider POST; provider disabled-model arrays survive strong parameters; non-owner provider configuration is refused; tool-call-only inference counts as explicit verification; Deep Research keeps full results server-side while returning compact valid JSON to the model.

Key remediation files: `app/models/tool_integration.rb`, `app/services/whatsapp_service.rb`, `app/jobs/agent_stream_job.rb`, `deploy/workspace_manager/manager.py`, `deploy/workspace_manager/test_manager.py`, `app/controllers/workspace_previews_controller.rb`, `spec/requests/workspace_preview_gateway_spec.rb`, `app/models/image_generation.rb`, `app/jobs/images/generate_job.rb`, `app/controllers/api/v1/models_controller.rb`, `app/services/llm/provider_settings.rb`, `app/services/research/deep_research.rb`, `app/services/agent_runner.rb`, and their focused specs. The pre-existing `bin/run-bonsai` context/KV setting line was inspected and preserved; Bonsai routing was not changed.

Final verification on 2026-11-24 (repository root; `DATABASE_URL` and `QUEUE_DATABASE_URL` unset; asdf Ruby 3.4.3 first on `PATH`):

| Gate | Result |
|---|---|
| Provider transport/settings/model | **197 examples, 0 failures**, 1.86s, exit 0 |
| Research/Tavily/tool registry/runner | **160 examples, 0 failures**, 2.61s, exit 0 |
| Provider + webfetch + capabilities | **457 examples, 0 failures**, 64.39s, exit 0 |
| Workspace requests | **62 examples, 0 failures**, 1.2s, exit 0 |
| Composer/queue/Stop/regenerate/browser | **133 examples, 0 failures**, 23.22s, exit 0 |
| Security/navigation/image lifecycle | **264 examples, 0 failures**, 10.83s, exit 0 |
| Lint-related focused regression | **127 examples, 0 failures**, 2s, exit 0 |
| Provider settings/chat UI browser | **52 examples, 0 failures**, 28.39s, exit 0 |
| Workspace manager unit tests | **13 tests, OK**, 35.725s, exit 0 |
| Ruby 3.4.3 syntax | **181 files OK**, exit 0 |
| JavaScript/TypeScript parse (Bun) | **7 files OK**, exit 0 |
| Active `webfetch` schema | required `url`; `markdown/text/html`; timeout 1–120; exit 0 |
| Flutter | `flutter analyze` clean; **107 tests passed**; exit 0 |
| Whitespace | `git diff --check` no output, exit 0 |
| RuboCop | **179 files, 2 pre-existing offenses** in `spec/services/sketches/create_spec.rb:52/:56`, exit 1; no new offenses |

Exact principal commands:

```sh
env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/services/llm/secure_http_spec.rb spec/services/llm/provider_endpoint_spec.rb spec/services/llm/provider_connection_spec.rb spec/services/llm/anthropic_adapter_spec.rb spec/services/llm/client_spec.rb spec/requests/api/v1/models_spec.rb spec/requests/settings_provider_architecture_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/services/research/deep_research_spec.rb spec/services/integrations/search_and_figma_spec.rb spec/services/agents/tool_registry_spec.rb spec/services/agent_runner_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/services/llm/*_spec.rb spec/services/webfetch_service_spec.rb spec/services/webfetch_integration_spec.rb spec/jobs/agent_stream_job_webfetch_spec.rb spec/services/capabilities/registry_spec.rb spec/requests/api/v1/models_spec.rb spec/requests/settings_provider_architecture_spec.rb spec/requests/agent_provider_scoped_models_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/requests/workspace_panel_spec.rb spec/requests/api/v1/workspaces_spec.rb spec/requests/workspace_preview_gateway_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/services/conversations/turn_admission_spec.rb spec/requests/conversation_tasks_spec.rb spec/requests/messages_spec.rb spec/requests/message_idempotency_spec.rb spec/requests/message_attachments_spec.rb spec/requests/message_tools_selection_spec.rb spec/requests/conversation_stop_spec.rb spec/requests/regenerate_spec.rb spec/jobs/agent_stream_job_spec.rb spec/system/composer_spec.rb spec/system/in_flight_guard_spec.rb spec/system/stalled_run_live_recovery_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/requests/users_spec.rb spec/requests/organizations_memberships_spec.rb spec/requests/organizations_plan_spec.rb spec/requests/run_authorization_spec.rb spec/models/run_spec.rb spec/requests/tool_integrations_marketplace_spec.rb spec/requests/whatsapp_webhook_spec.rb spec/requests/agents_index_spec.rb spec/requests/images_gallery_spec.rb spec/system/images_navigation_spec.rb spec/jobs/images/generate_job_spec.rb spec/models/image_generation_spec.rb spec/services/images/generator_spec.rb spec/services/assets/ingest_spec.rb spec/services/assets/validator_spec.rb spec/services/assets/extractors_spec.rb spec/jobs/asset_extraction_job_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/services/llm/anthropic_adapter_spec.rb spec/jobs/agent_stream_job_spec.rb spec/requests/api/v1/models_spec.rb spec/requests/workspace_preview_gateway_spec.rb

env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rspec spec/system/model_selector_spec.rb spec/system/conversation_model_switcher_spec.rb spec/system/agent_provider_scoped_models_spec.rb spec/system/settings_integrations_spec.rb spec/system/chat_ui_requirements_spec.rb spec/system/stop_button_spec.rb

python3 -B -m unittest discover -s deploy/workspace_manager -p 'test*.py'
/opt/homebrew/bin/flutter analyze && /opt/homebrew/bin/flutter test

count=0; while IFS= read -r file; do case "$file" in *.rb) if [ -f "$file" ]; then /Users/sham4/.asdf/installs/ruby/3.4.3/bin/ruby -c "$file" >/dev/null || exit 1; count=$((count + 1)); fi ;; esac; done < <({ git diff --name-only --diff-filter=ACM; git ls-files --others --exclude-standard; } | sort -u); printf 'Ruby 3.4.3 syntax OK: %s files\n' "$count"

{ git diff --name-only --diff-filter=ACM; git ls-files --others --exclude-standard; } | sort -u | /Users/sham4/.bun/bin/bun -e 'const input = await Bun.stdin.text(); const files = input.split("\n").filter((file) => /\.(js|mjs|cjs|ts)$/.test(file)); for (const file of files) { new Bun.Transpiler({ loader: file.endsWith(".ts") ? "ts" : "js" }).transformSync(await Bun.file(file).text()); } console.log(`JavaScript/TypeScript parse OK: ${files.length} files`);'

{ git diff --name-only --diff-filter=ACM; git ls-files --others --exclude-standard; } | sort -u | while IFS= read -r file; do case "$file" in *.rb) [ -f "$file" ] && printf '%s\n' "$file" ;; esac; done | xargs env -u DATABASE_URL -u QUEUE_DATABASE_URL PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rubocop --force-exclusion

env -u DATABASE_URL -u QUEUE_DATABASE_URL RAILS_ENV=test PATH="/Users/sham4/.asdf/installs/ruby/3.4.3/bin:$PATH" bundle exec rails runner 'schema = Agents::ToolRegistry.schemas(["webfetch"]).first; abort "webfetch tool missing" unless schema && schema[:name] == "webfetch"; parameters = schema[:parameters]; abort "url not required" unless parameters["required"] == ["url"]; abort "format invalid" unless parameters.dig("properties", "format", "enum") == %w[markdown text html]; abort "timeout invalid" unless parameters.dig("properties", "timeout", "minimum") == 1 && parameters.dig("properties", "timeout", "maximum") == 120; puts "webfetch registered with required url and bounded format/timeout"'

git diff --check
```

Limits remain explicit: no live provider/search/image request was made; full RSpec remains behind the disk-recovery gate; real Flask/Docker re-acceptance and the successful workspace browser path were not rerun; no deployment, restart, migration or push occurred; inherited environment proxies are bypassed but explicit user-configured provider proxies are not implemented; the two pre-existing Sketch RuboCop offenses remain; Flutter emitted two non-fatal hit-test warnings in existing UI tests; C2/H5 and M16 remain untouched.

### Official provider capability matrix — checked 2026-11-24
This matrix records documented API surface, not account entitlement, model-specific support or successful Shams AI inference. Per-model flags/limits remain unset unless discovered or explicitly configured; real readiness still requires a successful inference fingerprint.

| Provider | Shams default / enabled families | Discovery in Shams | Official documentation facts checked | Important boundary |
|---|---|---|---|---|
| OpenRouter | `chat_completions`; `responses` also enabled | OpenAI-compatible `/models` | Documents Chat Completions and Responses, SSE streaming and tool calling | Tool/parameter support varies by selected model/provider |
| Groq | `chat_completions` | OpenAI-compatible `/models` | Documents OpenAI compatibility and a separate Responses API; Chat Completions has documented unsupported fields | Shams enables Chat Completions only in this milestone; do not assume every OpenAI field/model is supported |
| Google AI Studio / Gemini | `chat_completions` | Native Gemini model listing | OpenAI compatibility page documents chat, streaming, function calling and model list/retrieve | Compatibility is documented as beta; Responses API support is not asserted here |
| Cerebras | `chat_completions` | OpenAI-compatible `/models` attempt; manual fallback | Official Chat Completions schema documents `/v1/chat/completions`, streaming and function/tool calling | Reasoning, image and strict-tool support are model/deployment-specific |
| NVIDIA NIM | `chat_completions` | Manual-only in Shams | Official LLM API page documents `https://integrate.api.nvidia.com` and `POST /v1/chat/completions`, and lists the four requested examples | Listing is not account access; no universal streaming/tool/context/rate claims are fabricated |
| Organization custom endpoint | Owner-selected `chat_completions` or `responses` | Manual registration; optional compatible discovery | No universal third-party contract | Owner must provide truthful model metadata; production SSRF/transport policy still applies |

Official sources: [OpenRouter API overview](https://openrouter.ai/docs/api-reference/overview), [Groq OpenAI compatibility](https://console.groq.com/docs/openai), [Google AI Studio OpenAI compatibility](https://aistudio.google.com/docs/openai), [Cerebras Chat Completions](https://inference-docs.cerebras.ai/api-reference/chat-completions), [NVIDIA NIM LLM APIs](https://docs.api.nvidia.com/nim/reference/llm-apis).

---

## TODO (ordered by current priority)

1. [ ] **M14 cleanup item #1 — brew cleanup (~3.3 GB).** Connect external drive → confirm under `/Volumes` with ≥ ~4 GiB free → back up the exact 37 targets from `/tmp/m14-brew-cleanup-manifest.txt` and record backup paths → run `brew cleanup` → measure `df -h /`. Approved in principle; drive not yet connected.
2. [ ] **M14 cleanup items #2–#5** (pnpm store, `~/.gradle`, rotated logs, dead Docker containers/volumes). NOT authorized — each needs individual approval + external backup first; Docker volumes preserved until contents and restore requirements are verified.
3. [x] **P0 Gate A — contain public gateway exposure. ✅ DONE 2026-11-20, live-verified:** gateway GET+POST → 403; `/login` 200; `/api/v1/csrf` 200; `/api/v1/capabilities` 401 (Rails); `/api/v1/models` 404 (Rails, proxy intact); `/cable` → 101 WebSocket upgrade.
4. [ ] **P0 Gate B — deploy the Rails gateway auth fix** with the next approved Docker rebuild (separate from containment; loopback :3002 keeps the old controller until then).
5. [ ] **Rotate the exposed OpenRouter key + purge/rotate `log/development.log`** (M15-A C3) — user action, recommended immediately regardless of other fixes.
6. [ ] **M15 remediation — in progress, each batch gated on separate approval.** Order per audit report §6: **C1 users IDOR — ✅ FIXED in tree 2026-11-20 (Batch 1):** `set_user` scoped to `current_user` with uniform 404 (no enumeration), `:email` removed from mass assignment (email editing stays in owner-scoped Settings::Profiles), profile email field now read-only; new `spec/requests/users_spec.rb` **15/15** (HTML + JSON), regression batch **96/96**, RuboCop clean (all exit 0); in tree/undeployed. **H1 marketplace credential exposure — ✅ FIXED in tree 2026-11-20 (Batch 2):** admin/owner gate on every `ToolIntegrationsController` action (plain members redirected, cross-org 404s kept), credential fields write-only in both the legacy form and the connect modal (blank submits preserve stored secrets; no stored secret rendered to HTML), explicit whitelists (credentials `api_key`/`webhook_secret`; config `webhook_url`/`timeout`/`phone_number_id`/`from_address`), member-facing Connect/Manage links hidden in tools panel + agent form; marketplace spec **29/29** (10 new H1 examples), regression batch **192/192** + settings system spec **5/5**, RuboCop clean (all exit 0); in tree/undeployed. **H4 membership escalation — ✅ FIXED in tree 2026-11-23 (Batch 3):** `owner` removed from assignable membership roles (no target-consent transfer flow exists; organization creation remains the sole owner bootstrap), model guards reserve owner memberships for `organization.owner`, block owner-role promotion/demotion and direct owner destruction (including `Organization#remove_user`), controller rejects owner/unknown role assignment and reports refused owner removal, UI offers only Member/Admin and no owner mutation controls; member/admin add, role-change, removal, owner bootstrap, and organization cascade remain functional. Focused request+model specs **27/27** (19 request + 8 model), regression batch **268/268**, RuboCop clean (all exit 0); in tree/undeployed. **H3 per-user run scoping — ✅ FIXED in tree 2026-11-23 (Batch 4):** run list/detail and agent-detail recent runs scoped to `current_user` through `Run.for_user`; API run detail composes `Run.in_organization(current_organization).for_user(current_user)`; foreign, orphan, cross-org and admin cross-user reads return uniform 404 without content, own-run payloads and organization access remain intact; `AgentRun` resume/switch-mode controls verified already per-user. New `spec/requests/run_authorization_spec.rb` **18/18**, regression batch **387/387**, RuboCop clean on all 5 touched files (all exit 0); in tree/undeployed. **H2 WhatsApp webhook security — ✅ FIXED in tree 2026-11-24 (Batch 5):** signature verification fails closed when configuration is missing; inbound routing resolves one unique active organization integration by `phone_number_id` instead of binding a global `Agent.first`; the exact integration ID is propagated to `AgentStreamJob`, and replies resolve it only through the conversation agent's organization with no global credential fallback. Focused H2 specs **16/16**, related regression **461/461**, and final tenant-isolation regressions passed (exit 0); RuboCop and `git diff --check` clean on touched files; in tree/undeployed. Next: C2 free-cap USER DECISION + H5 atomic reserve → H7/H8 throttles → M1/M2/M3 → C3/M4 log redaction → H6 gateway quota+validation (bundle with Gate B rebuild) → mediums/lows. Remaining acceptance tests in report §5.
7. [ ] **Non-admin public demo account + org split** — needs explicit approval and a `pg_dump` of the public DB first; blocked on M15 C1/H1 fixes for any untrusted tester (audit report §7).
8. [ ] **Deploy 2FA + account & security panel** — Docker rebuild + migrate (public `/account` currently 404s); deployment gated on approval.
9. [ ] **Verify web and Flutter security flows end-to-end** after deployment (2FA sign-in, recovery codes, session tracking).
10. [ ] **Re-verify open workspace workstreams** — workspace security boundary audit DONE 2026-11-20 (read-only): ownership scoping on web+API controllers, argv-only exec (Shellwords lexer, ≤32 tokens, timeout clamp), preview gateway 4-check gate (ownership/live token/port match/HTTP-only) + CSP + header allowlists, manager path-traversal guard, manager published 127.0.0.1:3005 only; workspace spec batch **63/63** green. Remaining: Flask end-to-end re-acceptance — needs Docker operations, gated until cleanup/approval.
11. [x] **Real web search, Figma, Deep Research, webfetch and image generation** — implemented and regression-tested in tree; backend readiness/authorization is authoritative and no fabricated results are returned. Live credentialed-provider acceptance and deployment remain outstanding.
12. [ ] **Stable public URL** — purchase domain (`shams-ai.net` appears free; Cloudflare Registrar preferred), then named tunnel to replace the rotating quick tunnel.
13. [ ] **Stripe payments + phone OTP** — user go-ahead, keys/price id; wire the `organization.plan` flip in webhook handlers (M15-A L3: handlers currently never flip plan — paid upgrades would be a no-op); Coffee Key = 90 days of the 20,000-token/day plan (decided).
14. [ ] **Full RSpec suite re-run** — deferred until disk recovery is verified; targeted runs only meanwhile.
15. [x] **Commit the preserved working tree** — explicit user approval received 2026-11-24 (`commit all!!`); the inspected 247-path pre-commit tree includes quota ledger, Stop button, model selection/providers/NVIDIA, P0 gateway auth, security work, M15 C1+H1+H4+H3+H2, M18, webfetch, capabilities, workspaces and this verification record. Local commit only; no push is authorized.
16. [ ] **M16 — PostgreSQL migration and cross-process transaction integrity** — next engineering milestone after M15; NOT started (user: do not start yet).
17. [ ] **Release-readiness assessment** — withheld until security blockers are resolved; do not mark the release ready before then.

---

## Pending / blocked — gates detail

| Item | Status | Gate |
|---|---|---|
| M14 cleanup item #1 (brew cleanup, ~3.3GB) | ⛔ approved in principle | External drive must be connected → backup of the 37 manifest targets → cleanup → `df -h /` measurement |
| M14 cleanup items #2–#5 (pnpm, gradle, logs, Docker) | ⛔ not authorized | Individual approval + backup each; Docker volumes preserved until contents/restore verified |
| Non-admin public demo account + org split | ⛔ pending | Explicit approval + `pg_dump` of public DB first |
| 2FA / security panel deployment | ⛔ gated | Docker rebuild + migrate; no deployment without approval |
| Stable public URL (named tunnel) | ⛔ blocked | No domain owned; `shams-ai.net` appears free, Cloudflare Registrar preferred |
| P0 Gate A — public gateway containment (Apache 403) | ✅ achieved 2026-11-20 | Live-verified: gateway 403, unaffected routes + `/cable` 101 pass |
| P0 Gate B — Rails gateway auth fix deployed | ⛔ outstanding | Next approved Docker rebuild; containment ≠ deployment |
| M15-A isolation audit (read-only) | ✅ complete 2026-11-20 | Report outside git tree; M15 implementation NOT achieved; no fixes without approval |
| M15 remediation (C1 IDOR, H1 keys, H4 roles, H3 runs, H2 webhook, quota/throttles) | 🔄 in progress — C1 ✅, H1 ✅, H4 ✅, H3 ✅, H2 ✅ in tree (undeployed) | Each batch needs separate approval; free-tier cap is a user decision |
| OpenRouter key rotation + dev-log purge (C3) | ⛔ pending user action | Key-format material verified present in `log/development.log` (21 lines) |
| Beta invite (untrusted tester) | ⛔ blocked | Audit verdict: not safe today — C1+H1+H4+H3+H2 fixed in tree but undeployed; free cap + atomic reserve, login throttle, approved rebuild still pending |
| Stripe payments + phone OTP | ⛔ pending | User go-ahead, keys/price id; Coffee Key = 90 days of the 20k-token/day plan (decided) |
| Full RSpec suite re-run | ⛔ deferred | Until disk recovery verified (targeted runs only for now) |
| Release readiness declaration | ⛔ withheld | Security blockers unresolved; do not mark release ready |

Known documented debt: 2 pre-existing RuboCop offenses in `spec/services/sketches/create_spec.rb:52/:56` — intentionally left untouched per instruction.

---

## Current state snapshot (2026-11-24)

- Pre-commit inventory: **247 actual paths = 140 tracked modified + 107 untracked**, reconciled with `git diff --name-only` and `git ls-files --others --exclude-standard`; `git status --short` reports **221 rows** because untracked directories are collapsed. Nothing deleted. The session-created `deploy/workspace_manager/__pycache__` was preserved outside the repository at `/tmp/shams-workspace-manager-pycache-20261124-final` and is not in the commit set. The user explicitly authorized one local commit of all inspected work; no push is authorized.
- Final verification: see §21. Targeted Rails batches, Cuprite browser batches, Python manager tests, Ruby/JavaScript parsing, Flutter analysis/tests and `git diff --check` pass; RuboCop has only the two documented pre-existing Sketch offenses. Full RSpec and real Flask/Docker re-acceptance remain gated. No live provider/search/image request was made.
- P0 gateway: **public exposure CONTAINED** (Apache 403, live-verified 2026-11-20; Gate A ✅). Rails auth fix tested in tree but **not deployed** (Gate B ⛔, next approved Docker rebuild).
- M15-A isolation audit COMPLETE 2026-11-20 (read-only; report at `/Users/sham4/bonsai227b-shamsai/m15a-beta-isolation-audit.md`, outside the git tree): 3 critical + 8 high gaps verified against source; **untrusted beta invite NOT safe today**. Batches 1–5 (C1 users IDOR, H1 marketplace credentials, H4 membership escalation, H3 run scoping, H2 WhatsApp webhook security) are fixed in tree and undeployed. H2 now includes fail-closed signature verification, unique organization integration routing and exact-integration outbound replies with no global fallback. C2/H5, H7/H8 and M16 remain unstarted.
- H2 deployment configuration (not changed): set `WHATSAPP_APP_SECRET` or credentials `whatsapp.app_secret`, keep `WHATSAPP_VERIFY_TOKEN` nonblank, and configure each active organization's WhatsApp integration with the matching `phone_number_id`. Missing signature configuration fails closed.
- Workspace boundary: ownership, argv-only execution, preview token/port gate, manager loopback/path guard, bounded subprocess/file/export buffering, request-size caps and relative-only preview redirects are covered. Docker-free manager tests **13/13** and workspace request batch **62/62** pass; real Flask/Docker re-acceptance remains pending.
- Existing secret blocker remains: a real OpenRouter-format key was previously verified in `log/development.log`; rotation and purge are user actions and the log was not opened or reproduced during this work.
- Disk: last recorded 24 GiB free / 95% used (improved from 12 GiB without agent deletion; cause unattributed).
- Public path: LIVE via supervised quick tunnel; current hostname always read from `~/.config/shams/tunnel_url`.
- Ports: dev :3001 (untouched), public Docker :3002 (loopback), Apache :80 (loopback), Bonsai :8080 (host-only).
- Standing constraints: local commit only as explicitly approved; no push/deployment/restart/migration/Docker mutation; preserve user/org data, Bonsai routing, encrypted credentials, streaming and idempotency; never expose keys or raw provider responses to the frontend; never fabricate inference success.