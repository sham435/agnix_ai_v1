# Shams شمس AgentOS

A production-ready, full-stack AI Agentic Agent Platform built with Rails 8.1+.

> **Better Coding, Smarter Agents**

[![Ruby](https://img.shields.io/badge/Ruby-3.4.3-red.svg)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/Rails-8.1.3-red.svg)](https://rubyonrails.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16+-blue.svg)](https://www.postgresql.org)

## Features

- **Modular Agent System** - Create, configure, and manage AI agents with custom prompts and tools
- **Pluggable LLM Providers** - Anthropic Claude, OpenAI, Google Gemini, Ollama (local)
- **Streaming Responses** - Real-time streaming via Action Cable + Turbo Streams
- **Function Calling** - Tool use registry with JSON Schema validation
- **RAG with pgvector** - Vector search for semantic memory retrieval
- **Conversation Memory** - Summarization and long-term storage
- **Stripe Billing** - Subscriptions, webhooks, usage-based metering
- **WhatsApp Integration** - Inbound/outbound messages via Cloud API
- **OAuth** - Google and GitHub authentication
- **Hotwire UI** - Turbo + Stimulus for SPA-like experience
- **Dark Mode** - Modern chat UI inspired by Claude.ai
- **Solid Stack** - Solid Queue, Solid Cache, Solid Cable (no Redis required)
- **Docker + Kamal 2** - Production deployment

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                     Frontend (Hotwire)               │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  Chat UI   │  │ Agent Builder │  │  Settings    │  │
│  │  (Turbo)   │  │  (Stimulus)  │  │  Pages       │  │
│  └──────┬─────┘  └──────┬───────┘  └──────┬───────┘  │
└─────────┼───────────────┼─────────────────┼──────────┘
          │               │                 │
┌─────────▼───────────────▼─────────────────▼──────────┐
│                     Rails 8.1 App                     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Controllers │  │  ViewComps   │  │  Channels    │ │
│  │ (REST + API)│  │  (UI)        │  │  (WebSocket) │ │
│  └──────┬──────┘  └──────────────┘  └──────┬───────┘ │
│         │                                   │         │
│  ┌──────▼───────────────────────────────────▼──────┐  │
│  │              Service Layer                       │  │
│  │  ┌────────────┐  ┌───────────┐  ┌────────────┐  │  │
│  │  │ AgentRunner│  │ LlmClient │  │ ToolReg    │  │  │
│  │  └────────────┘  └───────────┘  └────────────┘  │  │
│  │  ┌────────────┐  ┌───────────┐  ┌────────────┐  │  │
│  │  │ Embedding  │  │ Stripe    │  │ WhatsApp   │  │  │
│  │  └────────────┘  └───────────┘  └────────────┘  │  │
│  └──────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Background Jobs (Solid Queue)        │  │
│  │  AgentStream • Embedding • Summarize • Usage     │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────┬─────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────┐
│                   Data Layer                          │
│  ┌──────────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ PostgreSQL   │  │ Solid    │  │  Solid         │  │
│  │ + pgvector   │  │ Queue    │  │  Cache/Cable   │  │
│  └──────────────┘  └──────────┘  └────────────────┘  │
└──────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Ruby 3.4.3 (`rbenv` or `asdf` recommended)
- PostgreSQL 16+ with `vector` extension
- Node.js (for importmap)
- Redis 7+ (optional, Solid gems replace most Redis needs)

### Setup

```bash
# 1. Install dependencies
cd shams
bundle install

# 2. Setup database (PostgreSQL with pgvector)
# Make sure PostgreSQL 16+ is running with the vector extension
bin/rails db:create

# 3. Run migrations (includes pgvector extension)
bin/rails db:migrate

# 4. Seed demo data
bin/rails db:seed

# 5. Setup credentials
bin/rails credentials:edit
# Add your API keys (see config/credentials template below)

# 6. Start the app (terminal 1)
bin/dev
# Starts: Rails server (:3001) + Tailwind watcher + Solid Queue

# 7. Local model server (terminal 2, from the Shams repo root)
bin/run-bonsai             # Bonsai 2 27B on :8080
bin/run-bonsai 1bit        # 1-bit Bonsai 27B on :8910
```

Visit `http://localhost:3001` and login with:
- Email: `shams@shams.ai`
- Password: `password123`

### Local model server (Bonsai)

The `bonsai-*` agents talk to a local llama.cpp server that you run in its own
terminal, alongside `bin/dev`:

```bash
bin/run-bonsai          # terminal 2 - Bonsai 2 27B (ternary) on :8080
bin/dev                 # terminal 1 - web (:3001) + css + jobs
```

It is not an entry in `Procfile.dev` on purpose. Foreman terminates the whole
process group as soon as *any* process exits, and the model launcher exits
non-zero when its port already answers `/health`, so a "nice to have" model
server in the Procfile would take the app down with it.

The launcher resolves the Bonsai toolkit from its own location - the `bonsai227b`
checkout that sits next to this app - and takes these optional knobs from the
environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BONSAI_DIR` | `../../bonsai227b` (resolved from the app root) | Checkout holding `setup.sh` + `scripts/`. Set it if your weights/runtime live elsewhere. |
| `BONSAI_PORT` | `8080` (`8910` for `1bit`) | Port llama.cpp binds. Deliberately not `PORT`, because `bin/dev` owns that for the web server. |
| `BONSAI_FAMILY` | `bonsai2` (`bonsai` for `1bit`) | Weights family: `bonsai2`, `bonsai` (1-bit), `ternary`. The launcher pins it per branch. |
| `BONSAI_MODEL` | `27B` (size) | For the launcher this is the weights *size* (`27B`, `9B`, `8B`, `4B`, `2B`, `1.7B`). In the app's `.env` the same name holds the OpenAI request id (`bonsai-2-27b`); the launcher overrides it, so the two never collide. |
| `BONSAI_CTX` | auto (RAM-tiered) | Context window. Unset or `0` picks the tiered default. |

One-time weight download (~8GB for Bonsai 2 27B, ~4GB for the 1-bit build):

```bash
cd "$BONSAI_DIR" && BONSAI_OPENWEBUI=0 BONSAI_CODE_INTERPRETER=0 ./setup.sh
```

## Configuration

### Credentials

Edit credentials with `bin/rails credentials:edit`:

```yaml
anthropic:
  api_key: sk-ant-xxxxx

openai:
  api_key: sk-proj-xxxxx

stripe:
  secret_key: sk_test_xxxxx
  publishable_key: pk_test_xxxxx
  webhook_secret: whsec_xxxxx

postmark:
  api_token: xxxxx-xxxxx-xxxxx

whatsapp:
  access_token: xxxxx
  phone_number_id: xxxxx
  verify_token: my_verify_token
  auto_provision: true

google:
  client_id: xxxxx
  client_secret: xxxxx

github:
  client_id: xxxxx
  client_secret: xxxxx

sentry:
  dsn: https://xxxxx@sentry.io/xxxxx
```

### Environment Variables

```bash
# Database
DATABASE_URL=postgresql://user:pass@localhost/shams_production

# Rails
RAILS_ENV=production
RAILS_MAX_THREADS=10
WEB_CONCURRENCY=2
PORT=3000

# Solid Queue (config/queue.yml reads JOB_CONCURRENCY for the worker process count)
JOB_CONCURRENCY=2

# App
APP_HOST=shams.example.com
ALLOWED_ORIGINS=https://shams.example.com

# LLM (fallback if not in credentials)
ANTHROPIC_API_KEY=sk-ant-xxxxx
OPENAI_API_KEY=sk-proj-xxxxx
GOOGLE_API_KEY=AIzaXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
# Gemini speaks an OpenAI-compatible API; this is the default, change only to proxy it.
GOOGLE_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/v1
OLLAMA_HOST=http://localhost:11434
```

Any of these keys can be replaced per organization without a redeploy: paste it
on **Settings > Integrations** ("Model provider keys") and it is stored
encrypted on that organization's `ToolIntegration` row, which `Agent#api_key`
checks before credentials and ENV.

## Development

### Run tests

```bash
bundle exec rspec
bundle exec rubocop
bundle exec brakeman
bundle exec bundler-audit
```

### Database

```bash
bin/rails db:migrate          # Run migrations
bin/rails db:seed             # Seed demo data
bin/rails db:reset            # Reset and reseed
bin/rails console             # Rails console
```

### Docker

```bash
# Build
docker build -t shams .

# Run with docker-compose (local dev with Postgres + Redis)
docker-compose up -d

# Run app
docker run -p 3000:3000 \
  -e DATABASE_URL=postgresql://postgres:postgres@host.docker.internal/shams_development \
  shams
```

### Deployment with Kamal 2

```bash
# Install Kamal
gem install kamal

# Configure (edit config/deploy.yml)
kamal setup

# Deploy
kamal deploy

# Rollback
kamal rollback

# Check status
kamal status
```

## Project Structure

```
shams/
├── app/
│   ├── channels/          # Action Cable channels
│   │   └── application_cable/
│   │   └── streaming_channel.rb
│   ├── components/        # ViewComponent classes
│   ├── controllers/       # Rails controllers
│   │   ├── api/v1/       # JSON API
│   │   └── webhooks/     # Webhook handlers
│   ├── jobs/              # Background jobs (Solid Queue)
│   ├── models/            # ActiveRecord models
│   ├── services/          # Service objects
│   │   ├── llm/          # LLM provider adapters
│   │   ├── tools/        # Tool implementations
│   │   └── integrations/ # Third-party integrations
│   └── views/             # ERB + Tailwind views
├── config/
│   ├── deploy.yml        # Kamal 2 deploy config
│   ├── queue.yml         # Solid Queue config
│   ├── cable.yml         # Solid Cable config
│   ├── cache.yml         # Solid Cache config
│   └── importmap.rb      # Importmap pins
├── db/
│   ├── migrate/          # Database migrations
│   └── seeds.rb          # Demo data
├── spec/                 # RSpec tests
├── Dockerfile            # Multi-stage Docker build
├── docker-compose.yml    # Local dev services
├── Gemfile               # Dependencies
└── Procfile.dev          # Development processes
```

## API Endpoints

### Conversations

```
GET    /conversations           # List conversations
POST   /conversations           # Create conversation
GET    /conversations/:id       # Show conversation
DELETE /conversations/:id       # Archive conversation
POST   /conversations/:id/regenerate  # Regenerate response
POST   /conversations/:id/stop        # Stop generation
```

### Messages

```
POST   /conversations/:id/messages  # Send message (triggers agent)
```

### Agents

```
GET    /agents               # List agents
POST   /agents               # Create agent
GET    /agents/:id           # Show agent
PATCH  /agents/:id           # Update agent
DELETE /agents/:id           # Delete agent
GET    /agents/:id/test      # Test playground
POST   /agents/:id/test      # Run test
```

### API v1 (JSON)

```
GET    /api/v1/conversations     # List conversations
POST   /api/v1/conversations/:id/messages  # Send message
GET    /api/v1/agents            # List agents
GET    /api/v1/runs/:id          # Show run status
```

### Webhooks

```
POST   /webhooks/stripe          # Stripe webhook events
POST   /webhooks/whatsapp        # WhatsApp webhook events
GET    /webhooks/whatsapp        # WhatsApp webhook verification
```

## Security

- **CSRF Protection** - Built-in Rails CSRF tokens
- **CSP** - Content Security Policy configured
- **Force SSL** - HTTPS enforced in production
- **Secure Cookies** - HttpOnly, Secure, SameSite
- **Encrypted Credentials** - Rails encrypted credentials
- **Rate Limiting** - Per-user and per-IP limits
- **Parameter Filtering** - Sensitive params filtered from logs
- **Brakeman** - Static security analysis in CI

## License

MIT License. See LICENSE for details.

---

Built with ❤️ by Shams شمس
