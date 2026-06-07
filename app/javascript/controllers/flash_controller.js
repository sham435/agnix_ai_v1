import { Controller } from "@hotwired/stimulus"

// Flash message auto-dismiss controller.
export default class extends Controller {
  connect() {
    setTimeout(() => {
      this.element.style.transition = "opacity 0.3s, transform 0.3s"
      this.element.style.opacity = "0"
      this.element.style.transform = "translateY(-10px)"
      setTimeout(() => this.element.remove(), 300)
    }, 4000)
  }
}
