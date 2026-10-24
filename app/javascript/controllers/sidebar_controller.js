import { Controller } from "@hotwired/stimulus"

// Phase 1a — app shell sidebar behaviour.
//
// Two independent, persisted interaction modes:
//   * Desktop (>= 1024px): a width toggle between the full 288px panel and a
//     64px icon-rail. Preference lives in localStorage["shams.sidebar"] so the
//     choice survives navigation and reloads.
//   * Mobile (< 1024px): the sidebar is an off-canvas drawer with a backdrop;
//     the hamburger opens it, the backdrop / Escape closes it.
// ⌘B / Ctrl+B collapses on desktop and toggles the drawer on mobile.
const STORAGE_KEY = "shams.sidebar"
const DESKTOP = "(min-width: 1024px)"

export default class extends Controller {
  static targets = ["sidebar", "overlay", "collapse"]

  connect() {
    this._onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this._onKey)
    this._onMenu = (e) => {
      if (e.target.closest("#menuBtn")) {
        e.preventDefault()
        this.openDrawer()
      }
    }
    document.addEventListener("click", this._onMenu)
    this._onResize = () => { if (this.isDesktop()) this.closeDrawer() }
    window.addEventListener("resize", this._onResize)
    this.setCollapsed(this.savedCollapsed(), { persist: false })
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKey)
    document.removeEventListener("click", this._onMenu)
    window.removeEventListener("resize", this._onResize)
  }

  isDesktop() {
    return typeof window.matchMedia === "function" && window.matchMedia(DESKTOP).matches
  }

  // ⌘B / hamburger entry point — does the right thing for the viewport.
  toggle() {
    if (this.isDesktop()) this.toggleCollapse()
    else this.toggleDrawer()
  }

  // -- Icon-rail collapse (desktop) --
  savedCollapsed() {
    try { return localStorage.getItem(STORAGE_KEY) === "rail" } catch (_e) { return false }
  }

  toggleCollapse() {
    const next = this.sidebarTarget.getAttribute("data-collapsed") !== "true"
    this.setCollapsed(next, { persist: true })
  }

  setCollapsed(collapsed, { persist }) {
    this.sidebarTarget.setAttribute("data-collapsed", String(collapsed))
    if (persist) {
      try { localStorage.setItem(STORAGE_KEY, collapsed ? "rail" : "full") } catch (_e) { /* private mode */ }
    }
    this.collapseTargets.forEach((btn) => {
      btn.setAttribute("aria-pressed", String(collapsed))
      const label = collapsed ? "Expand sidebar" : "Collapse sidebar"
      btn.setAttribute("aria-label", label)
      btn.setAttribute("title", `${label} (⌘B)`)
    })
  }

  // -- Mobile drawer --
  openDrawer() {
    this.sidebarTarget.setAttribute("data-open", "true")
    this.overlayTarget?.setAttribute("data-open", "true")
    document.body.classList.add("overflow-hidden")
    this.sidebarTarget.setAttribute("inert", "false")
  }

  closeDrawer() {
    this.sidebarTarget.setAttribute("data-open", "false")
    this.overlayTarget?.setAttribute("data-open", "false")
    document.body.classList.remove("overflow-hidden")
  }

  toggleDrawer() {
    if (this.sidebarTarget.getAttribute("data-open") === "true") this.closeDrawer()
    else this.openDrawer()
  }

  onKey(e) {
    const tag = document.activeElement?.tagName
    const typing = tag === "INPUT" || tag === "TEXTAREA" || document.activeElement?.isContentEditable

    if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === "b") {
      e.preventDefault()
      this.toggle()
      return
    }
    if (e.key === "Escape" && this.sidebarTarget.getAttribute("data-open") === "true") {
      this.closeDrawer()
    }
    void typing
  }
}
