import { Controller } from "@hotwired/stimulus"

// Phase 1c — global keyboard shortcuts for the shell.
//
//   ⌘/Ctrl+K   open the command-palette conversation search (⌘B is owned by the
//              sidebar controller; Escape is handled by each overlay's own
//              controller so nothing here steals it while typing).
//   ⌘/Ctrl+⇧+O start a new chat.
// The palette listens for the "shams:search" event we dispatch below, so this
// controller stays decoupled from the modal's markup.
export default class extends Controller {
  static values = { newChatUrl: { type: String, default: "/" } }

  connect() {
    this._onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this._onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKey)
  }

  onKey(e) {
    const meta = e.metaKey || e.ctrlKey
    if (!meta) return
    const key = e.key.toLowerCase()

    // ⌘K / Ctrl+K -> open the search palette.
    if (key === "k" && !e.shiftKey) {
      e.preventDefault()
      window.dispatchEvent(new CustomEvent("shams:search"))
      return
    }

    // ⌘⇧O / Ctrl+⇧O -> new chat.
    if (key === "o" && e.shiftKey) {
      e.preventDefault()
      this.newChat()
    }
  }

  newChat() {
    const url = this.newChatUrlValue || "/"
    if (window.Turbo && typeof window.Turbo.visit === "function") {
      window.Turbo.visit(url)
    } else {
      window.location.href = url
    }
  }
}
