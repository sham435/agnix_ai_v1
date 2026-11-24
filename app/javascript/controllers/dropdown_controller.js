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
    this.syncMenuState()
    if (this.element.hasAttribute("data-dropdown-hover")) {
      this.boundMouseEnter = () => {
        if (window.matchMedia("(hover: hover) and (pointer: fine)").matches) this.showMenu()
      }
      this.boundMouseLeave = () => {
        if (!this.element.contains(document.activeElement)) this.hideMenu()
      }
      this.element.addEventListener("mouseenter", this.boundMouseEnter)
      this.element.addEventListener("mouseleave", this.boundMouseLeave)
    }
  }

  disconnect() {
    document.removeEventListener("click", this.boundHide)
    document.removeEventListener("keydown", this.boundKey)
    if (this.boundMouseEnter) this.element.removeEventListener("mouseenter", this.boundMouseEnter)
    if (this.boundMouseLeave) this.element.removeEventListener("mouseleave", this.boundMouseLeave)
  }

  toggle(e) {
    e.stopPropagation()
    if (
      this.element.hasAttribute("data-dropdown-hover") &&
      window.matchMedia("(hover: hover) and (pointer: fine)").matches
    ) {
      this.showMenu()
    } else if (this.menuTarget.classList.contains("hidden")) {
      this.showMenu()
    } else {
      this.hideMenu()
    }
  }

  hide(e) {
    if (!this.element.contains(e.target)) this.hideMenu()
  }

  open() {
    this.showMenu()
    this.buttonTarget?.focus()
  }

  // For an item that opens something else (the account panel) — `hide` only
  // reacts to clicks outside the menu, so a menu item needs to close it itself.
  close() {
    this.hideMenu()
  }

  showMenu() {
    this.menuTarget.classList.remove("hidden")
    this.syncMenuState()
  }

  hideMenu() {
    this.menuTarget.classList.add("hidden")
    this.syncMenuState()
  }

  syncMenuState() {
    const hidden = this.menuTarget.classList.contains("hidden")
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", String(!hidden))
    this.menuTarget.setAttribute("aria-hidden", String(hidden))
  }

  onKey(e) {
    if (this.element.hasAttribute("data-dropdown-arrows")) {
      const menuWasOpen = !this.menuTarget.classList.contains("hidden")

      if (e.key === "Escape") {
        if (menuWasOpen) {
          this.hideMenu()
          if (this.element.contains(document.activeElement)) this.buttonTarget?.focus()
        }
        return
      }

      if (["ArrowDown", "ArrowUp"].includes(e.key)) {
        if (!this.element.contains(document.activeElement)) return

        const items = Array.from(this.menuTarget.querySelectorAll("a[href], button:not([disabled])"))
        if (items.length === 0) return
        e.preventDefault()

        if (!menuWasOpen) {
          this.showMenu()
          items[e.key === "ArrowDown" ? 0 : items.length - 1].focus()
          return
        }

        const current = items.indexOf(document.activeElement)
        const next = e.key === "ArrowDown" ? (current + 1) % items.length : (current <= 0 ? items.length - 1 : current - 1)
        items[next].focus()
        return
      }
    }

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
      this.hideMenu()
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
