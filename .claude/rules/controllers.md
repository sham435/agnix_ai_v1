---
globs: "app/controllers/**/*"
---
# Controller Constraints
- Skinny controllers: only params/permit/redirect/render.
- Never put database queries in controllers - use model scopes or service objects.
- Use strong params everywhere (`params.require().permit()`).
- Use `before_action` for authentication and authorization.
- Return appropriate HTTP status codes.
- Use `respond_to` blocks for format negotiation.
- No raw SQL or Active Record queries - delegate to models.
- Use `helper_method` to expose private methods to views.
- Keep `before_action` filters at the top of the class.
