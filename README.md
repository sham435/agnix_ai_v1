# Shams شمس AgentOS

A production-ready, full-stack AI Agentic Agent Platform built with Rails 8.1+.

> **Better Coding, Smarter Agents**

[![Ruby](https://img.shields.io/badge/Ruby-3.4.3-red.svg)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/Rails-8.1.3-red.svg)](https://rubyonrails.org)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16+-blue.svg)](https://www.postgresql.org)

## Features

- **Modular Agent System** - Create, configure, and manage AI agents with custom prompts and tools
- **Pluggable LLM Providers** - Anthropic Claude, OpenAI, Ollama (local)
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
cd agnix
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

# 6. Start the app
bin/dev
# Starts: Rails server + Tailwind watcher + Solid Queue
```

Visit `http://localhost:3000` and login with:
- Email: `shams@agnix.ai`
- Password: `password123`

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
DATABASE_URL=postgresql://user:pass@localhost/agnix_production

# Rails
RAILS_ENV=production
RAILS_MAX_THREADS=10
WEB_CONCURRENCY=2
PORT=3000

# Solid Queue
SOLID_QUEUE_WORKERS=2
SOLID_QUEUE_AGENT_WORKERS=1

# App
APP_HOST=agnix.example.com
ALLOWED_ORIGINS=https://agnix.example.com

# LLM (fallback if not in credentials)
ANTHROPIC_API_KEY=sk-ant-xxxxx
OPENAI_API_KEY=sk-proj-xxxxx
OLLAMA_HOST=http://localhost:11434
```

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
docker build -t agnix .

# Run with docker-compose (local dev with Postgres + Redis)
docker-compose up -d

# Run app
docker run -p 3000:3000 \
  -e DATABASE_URL=postgresql://postgres:postgres@host.docker.internal/agnix_development \
  agnix
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
agnix/
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
