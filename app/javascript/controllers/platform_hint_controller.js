import { Controller } from "@hotwired/stimulus"

// §6: swap the visible submit-combo hint (⌘↵ / Ctrl+↵ / ↵) to match the
// actual platform's keydown policy in chat_input_controller. Uses the same
// static platformOf() classifier so the hint and the handler never disagree,
// which is what makes the requirement "the keyboard shortcuts behave the way
// the UI advertises" hold in practice.
//
// Markup contract:
//   <span data-controller="platform-hint"
//         data-platform-hint-target="label">↵</span>
//
// The initial HTML ships the universal Enter glyph so a JS-disabled or slow
// first-paint environment still shows something meaningful. Once Stimulus
// connects we replace it based on the classified platform.
export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render()
  }

  render() {
    if (!this.hasLabelTarget) return
    const platform = this._platform()
    const text = platform === "mac" ? "⌘ ↵"
      : platform === "mobile" ? "↵"
      : "↵"
    this.labelTarget.textContent = text
    this.labelTarget.setAttribute("title",
      platform === "mac" ? "Press Command + Enter to send"
        : "Press Enter to send (Shift + Enter adds a newline)")
  }

  _platform() {
    // Reuse the composer's classifier when it is loaded; otherwise inline the
    // same heuristic so the hint still works on the dashboard before the
    // chat-input controller connects.
    const ci = this._chatInputClass()
    if (ci && typeof ci.platformOf === "function") return ci.platformOf()
    return this._fallbackPlatform()
  }

  _chatInputClass() {
    // The chat_input module is eager-imported in application.js; grab its
    // constructor from the already-registered Stimulus controller so we do
    // not have to import a second copy through the importmap graph.
    try {
      const ctrl = window.Stimulus?.getControllerForElementAndIdentifier?.(
        document.getElementById("messages-container") || document.body,
        "chat-input"
      )
      if (ctrl) return ctrl.constructor
      // Even with no live instance, the module still exports the class. We
      // can't import it here without a circular reference, so fall through
      // to the inline fallback.
    } catch (_e) { /* fall through */ }
    return null
  }

  _fallbackPlatform() {
    const nav = typeof navigator !== "undefined" ? navigator : {}
    const coarse = typeof window !== "undefined"
      && typeof window.matchMedia === "function"
      && window.matchMedia("(pointer: coarse)").matches
    const touch = (nav.maxTouchPoints || 0) > 0
    const token = (nav.userAgentData && nav.userAgentData.platform)
      || nav.platform || nav.userAgent || ""
    const looksMobile = /Android|iPhone|iPad|iPod|Mobile|Silk/i.test(token)
      || (coarse && touch)
    if (looksMobile) return "mobile"
    if (/Mac|iPhone|iPad|iPod/i.test(token)) return "mac"
    return "desktop"
  }
}
