import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "hint"]

  connect() {
    this.autosize()
    this.hintSeen = localStorage.getItem("chat_hint_seen") === "1"
    if (this.hintSeen) {
      this.hideHint(false)
    }
    this._lastLineCount = 1
    this._lastHintAt = 0
  }

  keydown(e) {
    const isEnter = e.key === "Enter"
    const submitCombo = isEnter && (e.metaKey || e.ctrlKey)
    const plainEnter = isEnter && !e.shiftKey && !e.metaKey && !e.ctrlKey

    if (submitCombo || plainEnter) {
      e.preventDefault()
      if (this.inputTarget.value.trim() === "") return
      this.element.requestSubmit()
    }
  }

  paste(e) {
    const text = (e.clipboardData || window.clipboardData).getData("text")
    if (text && text.includes("\n")) {
      this.showTempHint()
    }
  }

  autosize() {
    const el = this.inputTarget
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
    this.checkMultiline()
  }

  checkMultiline() {
    const lines = this.inputTarget.value.split("\n").length
    const now = Date.now()
    if (lines >= 3 && this._lastLineCount < 3 && now - this._lastHintAt > 10000) {
      this.showTempHint()
      this._lastHintAt = now
    }
    this._lastLineCount = lines
  }

  clear() {
    this.inputTarget.value = ""
    this.autosize()
    this.inputTarget.focus()
    this.hideHint(true)
    this._lastLineCount = 1
  }

  hideHint(animate = true) {
    if (!this.hasHintTarget) return
    if (animate) {
      this.hintTarget.style.opacity = "0"
      setTimeout(() => this.hintTarget.classList.add("hidden"), 300)
    } else {
      this.hintTarget.classList.add("hidden")
      this.hintTarget.style.opacity = "0"
    }
    localStorage.setItem("chat_hint_seen", "1")
    this.hintSeen = true
  }

  showTempHint() {
    if (!this.hasHintTarget) return
    this.hintTarget.classList.remove("hidden")
    requestAnimationFrame(() => {
      this.hintTarget.style.opacity = "1"
    })
    clearTimeout(this._hintTimeout)
    this._hintTimeout = setTimeout(() => {
      this.hintTarget.style.opacity = "0"
      setTimeout(() => this.hintTarget.classList.add("hidden"), 300)
    }, 3000)
  }
}
