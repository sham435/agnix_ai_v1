// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import { Application } from "@hotwired/stimulus"

// Register the redirect stream action (not built into Turbo 8).
window.Turbo.StreamActions.redirect = function () {
  const url = this.target || this.getAttribute("url")
  if (url) window.Turbo.visit(url)
}

// Eager load controllers manually for importmap (no require.context) AND
// register them. Importing a module only executes it — without an explicit
// `Stimulus.register(identifier, controller)` call none of the controllers
// would ever connect, breaking Enter-to-send, live streaming, hints, etc.
import ChatController from "controllers/chat_controller"
import ChatInputController from "controllers/chat_input_controller"
import FlashController from "controllers/flash_controller"
import ToastController from "controllers/toast_controller"
import AgentPlanController from "controllers/agent_plan_controller"
import RunTimerController from "controllers/run_timer_controller"
import DropdownController from "controllers/dropdown_controller"
import ConfirmModalController from "controllers/confirm_modal_controller"
import PlaygroundController from "controllers/playground_controller"
import ThinkingIndicatorController from "controllers/thinking_indicator_controller"
import ExecutionTraceController from "controllers/execution_trace_controller"
import ToolsPanelController from "controllers/tools_panel_controller"
import PlatformHintController from "controllers/platform_hint_controller"
import ThemeController from "controllers/theme_controller"
import SidebarController from "controllers/sidebar_controller"
import ShortcutsController from "controllers/shortcuts_controller"
import SearchPaletteController from "controllers/search_palette_controller"
import ScheduledFormController from "controllers/scheduled_form_controller"

window.Stimulus = Application.start()
window.Stimulus.register("chat", ChatController)
window.Stimulus.register("chat-input", ChatInputController)
window.Stimulus.register("flash", FlashController)
window.Stimulus.register("toast", ToastController)
window.Stimulus.register("agent-plan", AgentPlanController)
window.Stimulus.register("run-timer", RunTimerController)
window.Stimulus.register("dropdown", DropdownController)
window.Stimulus.register("confirm-modal", ConfirmModalController)
window.Stimulus.register("playground", PlaygroundController)
window.Stimulus.register("thinking-indicator", ThinkingIndicatorController)
window.Stimulus.register("execution-trace", ExecutionTraceController)
window.Stimulus.register("tools-panel", ToolsPanelController)
window.Stimulus.register("platform-hint", PlatformHintController)
window.Stimulus.register("theme", ThemeController)
window.Stimulus.register("sidebar", SidebarController)
window.Stimulus.register("shortcuts", ShortcutsController)
window.Stimulus.register("search-palette", SearchPaletteController)
window.Stimulus.register("scheduled-form", ScheduledFormController)
