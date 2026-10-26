// Closes the click-to-enlarge image modal rendered into the layout's
// top-level "modal" turbo frame. Clearing the frame's content is the
// turbo-rails idiom for dismissing frame-driven modals — no server round
// trip, no second modal system.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.previouslyFocused = document.activeElement
    document.body.classList.add("overflow-hidden")
    this.keyHandler = (event) => {
      if (event.key === "Escape") this.close(event)
    }
    document.addEventListener("keydown", this.keyHandler)
  }

  disconnect() {
    document.body.classList.remove("overflow-hidden")
    if (this.keyHandler) document.removeEventListener("keydown", this.keyHandler)
    if (this.previouslyFocused && document.contains(this.previouslyFocused)) {
      this.previouslyFocused.focus()
    }
  }

  close(event) {
    if (event) event.preventDefault()
    const frame = document.getElementById("modal")
    if (frame) frame.innerHTML = ""
    this.element.remove()
    document.body.classList.remove("overflow-hidden")
  }
}
