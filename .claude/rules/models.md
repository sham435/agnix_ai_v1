---
globs: "app/models/**/*"
---
# Model Constraints
- Use `has_many`, `belongs_to` with `inverse_of`.
- Validations via ActiveModel, custom validators in `app/validators`.
- Use `enum :status, { pending: 0, paid: 1 }` (symbol syntax).
- No business logic in callbacks. Use service objects.
- Use scopes for reusable query logic.
- Fat models, skinny controllers.
- All database logic stays in models - never in controllers or views.
- Use `dependent: :destroy` for associated records that need callbacks.
- Use `dependent: :delete_all` for fast deletion without callbacks.
- Use `counter_cache: true` and `touch: true` where appropriate.
