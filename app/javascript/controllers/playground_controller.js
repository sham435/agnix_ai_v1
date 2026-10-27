import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const form = this.element.querySelector("form")
    const btn = this.element.querySelector("#test_run_btn")
    const result = this.element.querySelector("#test-result")

    if (form) {
      form.addEventListener("submit", (e) => {
        btn.disabled = true
        btn.textContent = "Running..."
        result.classList.remove("hidden")
        result.textContent = "Sending request to model..."
      })
    }
  }
}