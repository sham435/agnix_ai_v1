import { Controller } from "@hotwired/stimulus"

// Live collapsible execution trace.
//
// Shows a lightweight, high-level status line (Connecting → Thinking →
// Generating response → Completed) plus tool activity, and starts COLLAPSED.
// The user can expand on demand to read the ordered step log. This controller
// deliberately NEVER receives or renders the model's raw private reasoning —
// it only consumes the throttled `status` events and `tool_call` events the
// server forwards.
//
// Contract with chat_controller:
//   * setPhase(phase, meta)  — driven by {type:"status"} events
//   * noteTool(name)         — driven by {type:"tool_call"} events
//   * finish()               — driven by {type:"completed"} (unless failed)
//   * fail(message)          — driven by {type:"failed"} or status:"failed"
//
// The animated dots (thinking-indicator controller) live inside the summary
// row; they are stopped and hidden as soon as we leave the "thinking" phase so
// no ghost spinner lingers once real text is streaming.
export default class extends Controller {
  static targets = ["summary", "phase", "log", "chevron"]

  PHASE_LABELS = {
    connecting: "Connecting…",
    thinking: "Shams AI is thinking",
    generating: "Generating response…",
    completed: "Completed",
    failed: "Failed",
  }

  connect() {
    this.expanded = false
    this.lastLoggedPhase = null
    this.terminal = false // true once completed/failed has been reached
    // Ensure a clean collapsed starting state regardless of server markup.
    if (this.hasLogTarget) this.logTarget.hidden = true
    if (this.hasChevronTarget) this.chevronTarget.setAttribute("aria-hidden", "true")
    if (this.hasSummaryTarget) this.summaryTarget.setAttribute("aria-expanded", "false")
  }

  toggle() {
    this.expanded = !this.expanded
    if (this.hasLogTarget) this.logTarget.hidden = !this.expanded
    this.element.classList.toggle("is-expanded", this.expanded)
    if (this.hasSummaryTarget) this.summaryTarget.setAttribute("aria-expanded", String(this.expanded))
  }

  // Update the one-line status and (for a NEW phase) append it to the log.
  setPhase(phase, meta = {}) {
    const label = this.PHASE_LABELS[phase] || phase
    if (this.hasPhaseTarget) this.phaseTarget.textContent = label

    // Only log a phase the first time we see it — thinking heartbeats repeat.
    if (phase !== this.lastLoggedPhase) {
      this.addStep(label)
      this.lastLoggedPhase = phase
    }

    // Leaving the thinking phase means the placeholder is dead: retire dots.
    if (phase === "generating" || phase === "completed" || phase === "failed") {
      this.stopDots()
    }

    if (phase === "failed") {
      this.terminal = true
      this.element.classList.add("is-failed")
      if (meta.error) this.addStep(`Error: ${meta.error}`, true)
    } else if (phase === "completed") {
      this.terminal = true
      this.element.classList.add("is-completed")
    }
  }

  noteTool(name) {
    if (!name) return
    this.addStep(`Running tool · ${name}`)
    // Tool activity implies we are past connecting.
    if (this.hasPhaseTarget && !this.terminal && this.lastLoggedPhase !== "generating") {
      // Keep the visible phase line informative without faking completion.
      this.phaseTarget.textContent = "Working…"
    }
  }

  finish() {
    if (this.terminal) return // a failure already owned the terminal state
    this.setPhase("completed")
  }

  fail(message) {
    this.setPhase("failed", { error: message })
  }

  addStep(text, isError = false) {
    if (!this.hasLogTarget) return
    const li = document.createElement("li")
    li.className = isError ? "execution-trace__step execution-trace__step--error" : "execution-trace__step"
    li.textContent = text
    this.logTarget.appendChild(li)
    // Auto-reveal the freshly appended step's presence via a subtle cue even
    // while collapsed; we never force-expand (that would hijack the layout).
  }

  stopDots() {
    const node = this.element.querySelector("[data-thinking-indicator]")
    if (!node) return
    const ctrl = this.application?.getControllerForElementAndIdentifier
      ? this.application.getControllerForElementAndIdentifier(node, "thinking-indicator")
      : null
    if (ctrl && typeof ctrl.stop === "function") ctrl.stop()
    node.hidden = true
  }
}
