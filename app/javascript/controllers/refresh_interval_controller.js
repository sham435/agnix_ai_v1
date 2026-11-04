import { Controller } from "@hotwired/stimulus"

// Re-fetches the process table while at least one run is still live, and stops
// the moment every row has exited. Polling a page that can no longer change is
// just self-inflicted load, so `live` is a value the server computes from the
// recorded transitions rather than something guessed from a timer here.
//
// Registered explicitly in app/javascript/application.js — importing this
// module alone would not connect it.
export default class extends Controller {
  static values = {
    live: { type: Boolean, default: false },
    interval: { type: Number, default: 3000 }
  }

  connect() {
    if (!this.liveValue) return
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    this.restoreListener?.()
    this.pending = false
  }

  refresh() {
    // A hidden tab is not being watched; do not spend a worker on it.
    if (document.hidden) return
    // A 3s tick can arrive before the previous visit has rendered (a slow
    // query, a blocked worker). Stacked visits would leak listeners and pile
    // up requests, so at most one poll is outstanding at a time.
    if (this.pending) return

    // The scroll container is this very element (`overflow-y-auto`), so a
    // whole-page visit would otherwise snap the table back to the top on every
    // tick — the classic content-jump a scheduler view must not have.
    const scrollTop = this.element.scrollTop
    const restored = () => {
      this.pending = false
      this.element.scrollTop = scrollTop
      document.removeEventListener("turbo:render", restored)
      this.restoreListener = null
    }
    this.pending = true
    document.addEventListener("turbo:render", restored)
    this.restoreListener = () => {
      document.removeEventListener("turbo:render", restored)
      this.pending = false
    }

    const frame = this.element.closest("turbo-frame")
    // Inside a <turbo-frame>, visiting the page URL is wrong — the frame owns
    // the content. Outside one, a plain page replace is what we want.
    const options = frame ? { frame: frame.id } : { action: "replace" }
    window.Turbo.visit(this.pollUrl(), options)
  }

  // Cache-busting stamp: without it a conditional/edge cache could hand back
  // the very snapshot we are trying to replace.
  pollUrl() {
    const url = new URL(window.location.href)
    url.searchParams.set("pcb_t", Date.now())
    return url.toString()
  }
}
