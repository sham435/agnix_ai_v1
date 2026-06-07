---
globs: "db/migrate/**/*,db/schema.rb"
---
# Database Architecture Constraints
- Always use snake_case for table and column names.
- Use `t.references` with `type: :uuid`, `foreign_key: true`.
- Add indexes for all foreign keys and search columns.
- Use `jsonb` for flexible config, never `json`.
- Never bypass ActiveRecord model layer in app code.
- Migrations must be reversible (`def change` preferred).
- Use `id: :uuid` for all tables.
- Do not add duplicate indexes - `t.references` auto-creates FK index.
- pgvector: use `t.column :embedding, :vector, limit: 1536`.
- pgvector: IVFFlat indexes require data in table before creation.
