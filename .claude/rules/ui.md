---
globs: "app/views/**/*,app/components/**/*,app/javascript/**/*,app/assets/**/*"
---
# UI Constraints
- Use Tailwind CSS utility classes for styling.
- Use ViewComponent for reusable UI components.
- Use Turbo Streams for real-time updates.
- Use Stimulus controllers for client-side behavior.
- Partials for reusable view fragments (`_partial_name.html.erb`).
- Keep views presentational - no business logic.
- Use helpers for view-specific presentation logic.
- Dark mode by default with `class` strategy.
- Color palette: dark neutral base (#080808), warm amber accent (#ff8a00).
- Font: Inter for UI, Noto Sans Arabic for Arabic text.
