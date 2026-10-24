import { Controller } from "@hotwired/stimulus"

// Tools panel: opens a capability/integrations popover from the composer's
// Tools button. Server-rendered content (from Capabilities::Registry) lists
// every advertised capability with its TRUTHFUL state (enabled /
// needs_authorization / disabled) so users never see a dead button pretending
// to be live. Escape, blur-outside, and re-click close the panel. Focus is
// moved into the panel on open and returned to the toggle on close so keyboard
// users are not stranded.
//
// The controller scopes itself to a wrapper element (data-controller="tools-panel")
// that contains both the toggle button and the panel body. Multiple scopes per
// page are supported (e.g. dashboard + in-conversation), each toggling its
// own panel.
export default class extends Controller {
  static targets = ["panel", "toggle"]

  connect() {
    // Close on Escape anywhere; a document click that lands outside the panel
    // closes too. Both handlers are added/removed on connect/disconnect to
    // avoid leaking listeners when Turbo replaces the composer.
    this._onKeydown = (e) => {
      if (e.key === "Escape" && this._open) {
        e.preventDefault()
        this.close({ restoreFocus: true })
      }
    }
    this._onDocClick = (e) => {
      if (!this._open) return
      // Ignore clicks inside the panel or on the toggle (toggle handles itself).
      if (this._contains(e.target)) return
      this.close({ restoreFocus: false })
    }
    document.addEventListener("keydown", this._onKeydown)
    document.addEventListener("click", this._onDocClick, true)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
    document.removeEventListener("click", this._onDocClick, true)
  }

  toggle(event) {
    event.preventDefault()
    if (this._open) this.close({ restoreFocus: true })
    else this.open()
  }

  open() {
    if (!this.hasPanelTarget) return
    this._open = true
    this.panelTarget.hidden = false
    this.panelTarget.setAttribute("aria-hidden", "false")
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", "true")
    // Move focus to the first interactive element (search box or first item)
    // so Tab stays inside the panel.
    const first = this.panelTarget.querySelector(
      "button:not([disabled]), a[href], input, select, textarea, [tabindex]:not([tabindex='-1'])"
    )
    if (first) first.focus()
  }

  close({ restoreFocus = true } = {}) {
    if (!this._open) return
    this._open = false
    if (this.hasPanelTarget) {
      this.panelTarget.hidden = true
      this.panelTarget.setAttribute("aria-hidden", "true")
    }
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", "false")
      if (restoreFocus) this.toggleTarget.focus()
    }
  }

  // Selecting an item collapses the panel; the item's own data-action / href
  // does the real work (activating a tool, opening the setup link, etc.).
  pick(event) {
    this.close({ restoreFocus: false })
    // Allow the click to propagate to any other handler on the same element.
  }

  _contains(node) {
    if (this.hasPanelTarget && this.panelTarget.contains(node)) return true
    if (this.hasToggleTarget && this.toggleTarget.contains(node)) return true
    return false
  }
}
