import { Controller } from "@hotwired/stimulus"

// Account & security panel — the right-side slide-over for everything about the
// account rather than the conversation.
//
// The controller is scoped to the app-shell root so any trigger on any signed-in
// page (chat header, sidebar, user menu) can open it with
// `data-action="click->account-panel#open"` plus a `data-...-url-param` naming
// the section to show. The sheet it drives is a target, not `this.element`:
// the CSS, the `inert` attribute and the dialog's tabindex all live on
// #account-panel, while the controller has to reach the triggers outside it.
//
// The frame has no `src` in the markup: nothing in the security sections is read
// until the panel is actually opened, so a normal page view costs no extra
// queries over what it did before this panel existed. Once open, the same URL
// reloads rather than reusing stale numbers — quota and device lists change
// while the tab sits open.
//
// Inert when closed, so its controls are unreachable by Tab through the page,
// and focus returns to whatever opened it.
export default class extends Controller {
  static targets = ["panel", "frame", "scroll"]

  connect() {
    this._onKeydown = (event) => {
      if (event.key === "Escape" && this.isOpen) this.close()
    }
    document.addEventListener("keydown", this._onKeydown)
    this.frameTarget.addEventListener("turbo:frame-load", this._onFrameLoad = () => {
      this.setBusy(false)
      this.focusFirstField()
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKeydown)
    this.frameTarget.removeEventListener("turbo:frame-load", this._onFrameLoad)
  }

  get isOpen() {
    return this.panelTarget.dataset.open === "true"
  }

  open(event) {
    event.preventDefault()
    this.opener = event.currentTarget

    this.panelTarget.dataset.open = "true"
    this.panelTarget.removeAttribute("inert")

    const url = event.params.url
    if (url) this.load(url)
  }

  close() {
    if (!this.isOpen) return

    this.panelTarget.dataset.open = "false"
    this.panelTarget.setAttribute("inert", "")

    if (this.opener?.isConnected) this.opener.focus()
    this.opener = null
  }

  // Actions inside the panel answer with the same frame, so Turbo redraws it on
  // its own. This path is only for opening a section from the page chrome.
  load(url) {
    if (this.loadedUrl === url) {
      this.loadedUrl = null
      this.frameTarget.reload()
      return
    }
    this.loadedUrl = url
    this.setBusy(true)
    this.frameTarget.src = url
  }

  setBusy(busy) {
    if (this.hasScrollTarget) this.scrollTarget.dataset.busy = busy ? "true" : "false"
  }

  // A form-first section (the 2FA code box, the phone number field) is where the
  // user was heading; otherwise park focus on the dialog itself so Escape works
  // from the first keystroke.
  focusFirstField() {
    const active = document.activeElement
    if (active?.closest("#account-panel")) return

    const field = this.frameTarget.querySelector("input:not([type=hidden]), select, textarea")
    if (field) field.focus()
    else this.panelTarget.focus()
  }
}
