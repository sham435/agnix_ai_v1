# Agnix - Shams AgentOS • Claude Code Guide

## System Rules & Constraints
- Ruby 3.4+, Rails 8.1.3+, PostgreSQL 16+, Redis 7+
- Database Schema: Must strictly conform to PostgreSQL 16 and Rails naming conventions.
- ActiveRecord is the single source of truth. Never bypass models with raw SQL unless in a migration.
- Code style: RuboCop Rails Omakase, no trailing whitespace.
- Security: Encrypted credentials only, strong params everywhere, Brakeman clean.

## Tech Stack
- **Backend**: Rails 8.1.3, Ruby 3.4.3, PostgreSQL 16 (pgvector)
- **Frontend**: Hotwire Turbo + Stimulus, Tailwind CSS, ViewComponent
- **Background Jobs**: Solid Queue (persistent queue)
- **Caching**: Solid Cache
- **WebSockets**: Solid Cable (Action Cable via PostgreSQL)
- **AI**: Anthropic Claude, OpenAI, Ollama (pluggable via Llm::Client)
- **Integrations**: Stripe, WhatsApp Cloud API, Postmark, OAuth

## Phased Execution Roadmap
- [x] Phase 1: Core Schemas and Database Migrations
- [x] Phase 2: Models, Associations, Validations
- [ ] Phase 3: Service Objects and Agents Core (AgentRunner, LlmClient, ToolRegistry)
- [ ] Phase 4: Controllers, Hotwire Views, Components
- [ ] Phase 5: Integrations - Stripe, WhatsApp Cloud API, OAuth
- [ ] Phase 6: Background Jobs, Streaming, RAG
- [ ] Phase 7: Tests, Security Audit, Deploy

## Project Structure
```
agnix/
├── app/
│   ├── channels/         # Action Cable channels
│   ├── components/       # ViewComponent classes
│   ├── controllers/      # Rails controllers
│   ├── helpers/          # View helpers
│   ├── javascript/       # Stimulus controllers
│   ├── jobs/             # Solid Queue background jobs
│   ├── models/           # ActiveRecord models
│   ├── services/         # Service objects (Llm, Tools, Integrations)
│   └── views/            # ERB templates
├── config/               # Rails configuration
├── db/migrate/           # Database migrations
├── spec/                 # RSpec tests
├── .claude/rules/        # AI agent rules
└── rails_active_record.md # Active Record implementation guide
```

## Key Files
- `rails_active_record.md` - Complete Active Record & MVC guidelines
- `.claude/rules/database.md` - Database constraints
- `.claude/rules/models.md` - Model constraints
- `.claude/rules/controllers.md` - Controller constraints
- `.claude/rules/services.md` - Service object constraints
- `.claude/rules/ui.md` - UI/View constraints

## Demo Credentials
- Email: shams@agnix.ai / Password: password123
