---
globs: "app/services/**/*"
---
# Service Object Constraints
- One public method `.call`.
- Initialize with keyword args.
- Return Result monad or raise domain error.
- No direct controller params access.
- Complex business logic belongs in service objects, not models or controllers.
- Each service should have a single, clear responsibility.
- Use `raise` for exceptional cases, return values for expected failures.
- Service names should describe actions: `AgentRunner`, `StripeService`, `EmbeddingService`.
