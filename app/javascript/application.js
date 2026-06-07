// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import { Application, Controller } from "@hotwired/stimulus"

// Register the redirect stream action (not built into Turbo 8).
window.Turbo.StreamActions.redirect = function () {
  const url = this.target || this.getAttribute("url")
  if (url) window.Turbo.visit(url)
}

window.Stimulus = Application.start()

// Eager load controllers manually for importmap (no require.context).
import "controllers/chat_controller"
import "controllers/chat_input_controller"
import "controllers/flash_controller"
import "controllers/toast_controller"
import "controllers/agent_plan_controller"
import "controllers/run_timer_controller"
import "controllers/dropdown_controller"
import "controllers/confirm_modal_controller"
