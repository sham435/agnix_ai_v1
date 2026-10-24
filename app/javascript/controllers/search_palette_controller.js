import { Controller } from "@hotwired/stimulus"

// Phase 1c — ⌘K command palette: fuzzy search over the current user's
// conversations, backed by GET /conversations/search (server enforces the
// owner + active scope). Opens on the "shams:search" window event dispatched by
// the shortcuts controller, closes on Escape or backdrop click.
export default class extends Controller {
  static targets = ["modal", "input", "results", "empty"]
  static values = { searchUrl: { type: String, default: "/conversations/search" } }

  connect() {
    this._onOpen = () => this.open()
    this._onDocKey = (e) => { if (e.key === "Escape" && this.isOpen()) this.close() }
    window.addEventListener("shams:search", this._onOpen)
    document.addEventListener("keydown", this._onDocKey)
  }

  disconnect() {
    window.removeEventListener("shams:search", this._onOpen)
    document.removeEventListener("keydown", this._onDocKey)
  }

  isOpen() { return !this.modalTarget.hidden }

  open() {
    this.modalTarget.hidden = false
    document.body.classList.add("overflow-hidden")
    // Reset to a recent list on open; focus the field for immediate typing.
    this.load("")
    requestAnimationFrame(() => this.inputTarget?.focus())
  }

  close() {
    this.modalTarget.hidden = true
    document.body.classList.remove("overflow-hidden")
    if (this.hasInputTarget) this.inputTarget.value = ""
  }

  backdrop(e) {
    if (e.target === this.modalTarget) this.close()
  }

  // Debounced input -> search.
  query() {
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this.load(this.inputTarget.value), 180)
  }

  async load(term) {
    const url = `${this.searchUrlValue}?q=${encodeURIComponent(term || "")}`
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error("bad status")
      const data = await res.json()
      this.render(data.results || [])
    } catch (_e) {
      this.render([])
      if (this.hasEmptyTarget) this.emptyTarget.textContent = "Couldn't load results — try again."
    }
  }

  render(items) {
    if (!this.hasResultsTarget) return
    this.resultsTarget.textContent = ""
    if (!items.length) {
      this.resultsTarget.hidden = true
      if (this.hasEmptyTarget) { this.emptyTarget.hidden = false; this.emptyTarget.textContent = "No conversations match." }
      return
    }
    this.resultsTarget.hidden = false
    if (this.hasEmptyTarget) this.emptyTarget.hidden = true

    const frag = document.createDocumentFragment()
    items.forEach((item) => {
      const a = document.createElement("a")
      a.href = item.path
      a.className = "flex items-center gap-3 rounded-lg px-3 py-2 text-[14px] text-fg hover:bg-hover transition"
      const title = document.createElement("span")
      title.className = "min-w-0 flex-1 truncate"
      title.textContent = item.title || "Untitled conversation"
      const agent = document.createElement("span")
      agent.className = "shrink-0 text-[12px] text-fg-subtle"
      agent.textContent = item.agent || ""
      a.append(title, agent)
      frag.appendChild(a)
    })
    this.resultsTarget.appendChild(frag)
  }

  // Enter on the input jumps to the top result.
  onKeydown(e) {
    if (e.key === "Enter") {
      const first = this.resultsTarget?.querySelector("a")
      if (first) { e.preventDefault(); window.location.href = first.href }
    }
  }
}
