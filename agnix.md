# Agnix Rails Auto-Fixing Guidelines

## Rails Specific Constraints
- Do not alter `db/schema.rb` or create migrations autonomously
- Prioritize fixes in `app/models` and `app/controllers` using existing columns
- Respect Strong Parameters in all controller changes
- Do not introduce N+1 queries. Use `includes` or `preload` when touching ActiveRecord
- Keep callbacks idempotent

## Minimal Patching Rules
- Never replace an entire controller action if a single line conditional suffices
- Prefer guard clauses over deep nesting
- If a fix breaks an existing helper or decorator, rollback with `git checkout`
- Limit diff to 30 lines max per iteration
- Always run the targeted spec after patch

## Safety
- Only edit files matching `app/(models|services|controllers|components)/.*\.rb`
- Cap retries at 5
- Persist full stderr, diff, and test output to `log/auto_fixes/`
