import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.boundKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.boundKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKey)
  }

  show() {
    this.element.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  hide() {
    this.element.classList.add("hidden")
    document.body.style.overflow = ""
  }

  cancel() {
    this.hide()
  }

  onKey(e) {
    if (this.element.classList.contains("hidden")) return
    if (e.key === "Escape") {
      e.preventDefault()
      this.hide()
    }
  }
}
