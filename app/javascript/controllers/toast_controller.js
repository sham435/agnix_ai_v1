import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.show(this.element.dataset.message)
  }

  show(message) {
    const container = document.getElementById("toast-container")
    const el = document.createElement("div")
    el.className = "pointer-events-auto rounded-xl bg-elevated/95 border border-emerald-500/30 px-4 py-2 text-sm text-emerald-600 dark:text-emerald-400 shadow-lg backdrop-blur"
    el.textContent = message
    container.appendChild(el)
    setTimeout(() => el.remove(), 3000)
  }
}
