import { Controller } from "@hotwired/stimulus"

// Chat input controller - handles auto-resize textarea, keyboard shortcuts, and file attach.
export default class extends Controller {
  static targets = ["input", "form", "fileInput"]

  connect() {
    this.autoResize()
  }

  autoResize() {
    if (!this.hasInputTarget) return

    this.inputTarget.addEventListener("input", () => {
      this.inputTarget.style.height = "auto"
      this.inputTarget.style.height = Math.min(this.inputTarget.scrollHeight, 160) + "px"
    })

    // Cmd/Ctrl+Enter to submit.
    this.inputTarget.addEventListener("keydown", (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        this.submit()
      }
    })
  }

  submit() {
    if (this.hasFormTarget && this.inputTarget.value.trim()) {
      this.formTarget.requestSubmit()
    }
  }

  attach() {
    if (this.hasFileInputTarget) {
      this.fileInputTarget.click()
    }
  }
}
