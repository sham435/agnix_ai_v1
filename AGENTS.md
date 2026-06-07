# AGENTS.md - Agent Roles & Guardrails

## Agent Roles
- **schema_agent**: owns `db/migrate/**/*` and `db/schema.rb`
- **model_agent**: owns `app/models/**/*` and `app/models/concerns/**/*`
- **service_agent**: owns `app/services/**/*`
- **controller_agent**: owns `app/controllers/**/*` and `config/routes.rb`
- **ui_agent**: owns `app/views/**/*`, `app/components/**/*`, `app/javascript/**/*`
- **integration_agent**: owns `app/services/integrations/**/*` and webhook controllers

## Guardrails
- Never edit files outside assigned globs.
- Never generate TODO comments or placeholders.
- Always run RuboCop and RSpec before marking phase complete.
- Never commit secrets. Use `Rails.application.credentials`.
- Follow `rails_active_record.md` for all Active Record implementations.
- Load `.claude/rules/*.md` when working within matching file scopes.
- All database logic MUST reside in models - never in controllers or views.
- Use service objects for complex business logic.
