import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.boundHide = this.hide.bind(this)
    document.addEventListener("click", this.boundHide)
    this.boundKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.boundKey)
    this.keyBuffer = ""
    this.keyTimer = null
  }

  disconnect() {
    document.removeEventListener("click", this.boundHide)
    document.removeEventListener("keydown", this.boundKey)
  }

  toggle(e) {
    e.stopPropagation()
    this.menuTarget.classList.toggle("hidden")
  }

  hide(e) {
    if (!this.element.contains(e.target)) {
      this.menuTarget.classList.add("hidden")
    }
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    this.buttonTarget?.focus()
  }

  // For an item that opens something else (the account panel) — `hide` only
  // reacts to clicks outside the menu, so a menu item needs to close it itself.
  close() {
    this.menuTarget.classList.add("hidden")
  }

  onKey(e) {
    // Several dropdowns share a page (sidebar menu, chat header menu, composer
    // pickers). The shortcuts belong to the user menu only, and when the chat
    // page renders two of them the last one wins, so one keystroke opens one menu.
    const userMenus = document.querySelectorAll('[data-controller~="dropdown"][data-user-menu]')
    if (userMenus[userMenus.length - 1] !== this.element) return

    const active = document.activeElement
    const isTyping = active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)

    if (e.shiftKey && e.key.toLowerCase() === "l" && !isTyping) {
      e.preventDefault()
      this.openLogoutModal()
      return
    }

    if (isTyping) return

    clearTimeout(this.keyTimer)
    this.keyBuffer += e.key.toLowerCase()
    this.keyTimer = setTimeout(() => this.keyBuffer = "", 800)

    if (this.keyBuffer.endsWith("ga")) {
      e.preventDefault()
      this.open()
      this.keyBuffer = ""
    }

    if (e.key === "Escape") {
      this.menuTarget.classList.add("hidden")
    }
  }

  openLogoutModal() {
    const modal = document.getElementById("logout-modal")
    if (modal) {
      modal.classList.remove("hidden")
      document.body.style.overflow = "hidden"
    }
  }
}
