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
import ImagesModalController from "controllers/images_modal_controller"
import ProviderModelsController from "controllers/provider_models_controller"
import AutoSubmitController from "controllers/auto_submit_controller"
import RefreshIntervalController from "controllers/refresh_interval_controller"
import AccountPanelController from "controllers/account_panel_controller"
import WorkspacePanelController from "controllers/workspace_panel_controller"
import ModelSelectorController from "controllers/model_selector_controller"

window.ShamsNavigationState = {
  key() {
    const user = document.querySelector('[data-navigation-user-id]')?.dataset.navigationUserId
    const path = location.pathname === '/images' ? `/images:${new URLSearchParams(location.search).get('conversation_id') || 'direct'}` : location.pathname
    return user ? `shams-navigation:${user}:${path}` : null
  },
  read() {
    try { return JSON.parse(sessionStorage.getItem(this.key()) || '{}') } catch { return {} }
  },
  save() {
    const key = this.key()
    if (!key) return
    const input = document.querySelector('#message-input, #composer-input, #image_generation_prompt')
    if (!input) return
    const state = { draft: input.value, scroll: document.querySelector('#messages-container')?.scrollTop }
    if (location.pathname === '/images') {
      state.configuration = Object.fromEntries(Array.from(document.querySelectorAll('select[name^="image_generation["]')).map(field => [field.name, field.value]))
    }
    try { sessionStorage.setItem(key, JSON.stringify(state)) } catch {}
  },
  restoreDraft(input) {
    const state = this.read()
    if (typeof state.draft === 'string') input.value = state.draft
  },
  restoreScroll(container) {
    const state = this.read()
    if (typeof state.scroll !== 'number') return false
    container.scrollTop = state.scroll
    return true
  }
}

document.addEventListener('input', () => window.ShamsNavigationState.save())
document.addEventListener('change', () => window.ShamsNavigationState.save())
document.addEventListener('scroll', event => {
  if (event.target.id === 'messages-container') window.ShamsNavigationState.save()
}, true)
document.addEventListener('turbo:before-visit', () => window.ShamsNavigationState.save())
window.addEventListener('pagehide', () => window.ShamsNavigationState.save())
document.addEventListener('turbo:load', () => {
  if (location.pathname !== '/images') return
  const input = document.querySelector('#image_generation_prompt')
  if (input) window.ShamsNavigationState.restoreDraft(input)
  const state = window.ShamsNavigationState.read()
  for (const field of document.querySelectorAll('select[name^="image_generation["]')) {
    if (state.configuration?.[field.name]) field.value = state.configuration[field.name]
  }
})
document.addEventListener('turbo:submit-end', event => {
  if (!event.detail.success || !event.target.querySelector('#image_generation_prompt')) return
  document.querySelector('#image_generation_prompt').value = ''
  window.ShamsNavigationState.save()
})

window.Stimulus = Application.start()
window.Stimulus.register("model-selector", ModelSelectorController)
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
window.Stimulus.register("images-modal", ImagesModalController)
window.Stimulus.register("provider-models", ProviderModelsController)
window.Stimulus.register("auto-submit", AutoSubmitController)
window.Stimulus.register("refresh-interval", RefreshIntervalController)
window.Stimulus.register("account-panel", AccountPanelController)
window.Stimulus.register("workspace-panel", WorkspacePanelController)
