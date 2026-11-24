import { Controller } from "@hotwired/stimulus"

// Coding Workspace panel — the right-side slide-over for the Docker sandbox
// this conversation is running in.
//
// Scoped to the app-shell root like the account panel, so a trigger on any
// signed-in page opens it with `data-action="click->workspace-panel#open"` and
// a `data-...-url-param` naming what to show. The sheet is a target, not
// `this.element`: the CSS, `inert` and the dialog's tabindex live on
// #workspace-panel while the controller reaches the triggers outside it.
//
// The frame carries no `src` in the markup. Reading a sandbox is a manager
// round-trip — and, for the files tab, a container exec — so a page view that
// never opened the panel must not pay for it.
export default class extends Controller {
  static targets = ["panel", "frame", "scroll"]

  connect() {
    this._onKeydown = (event) => {
      if (event.key === "Escape" && this.isOpen) this.close()
    }
    document.addEventListener("keydown", this._onKeydown)
    this.frameTarget.addEventListener("turbo:frame-load", this._onFrameLoad = () => {
      this.setBusy(false)
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
  // its own. This path is only for opening it from the page chrome, and it
  // always reloads: a sandbox that has been running for five minutes is not the
  // sandbox that was rendered five minutes ago.
  load(url) {
    this.setBusy(true)
    if (this.loadedUrl === url && this.frameTarget.src) {
      this.frameTarget.reload()
      return
    }
    this.loadedUrl = url
    this.frameTarget.src = url
  }

  setBusy(busy) {
    if (this.hasScrollTarget) this.scrollTarget.dataset.busy = busy ? "true" : "false"
  }
}
