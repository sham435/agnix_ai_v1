import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { startedAt: String, status: String }
  static targets = ["label", "duration"]

  connect() {
    this.start = new Date(this.startedAtValue).getTime()
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    if (!["planning", "executing"].includes(this.statusValue)) {
      this.durationTarget.textContent = ""
      return
    }
    const secs = Math.floor((Date.now() - this.start) / 1000)
    this.durationTarget.textContent = `· ${this.format(secs)}`
  }

  format(s) {
    if (s < 60) return `${s}s`
    const m = Math.floor(s / 60)
    const r = s % 60
    return `${m}m ${r}s`
  }
}
