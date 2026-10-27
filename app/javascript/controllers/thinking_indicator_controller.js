import { Controller } from "@hotwired/stimulus"

// Animated growing-dots thinking indicator.
//
// Cycles the visible dot count 1 -> 2 -> 3 -> 1 on a fixed interval
// (default 400 ms). The number of dots is exposed on the root element via
// `data-dot-count` so system specs can observe state transitions without
// racing the animation clock. A `sr-only` label ("Shams AI is thinking")
// lives inside an `aria-live="polite"` region; the visible dots are marked
// `aria-hidden="true"` so screen readers announce the state once, not on
// every frame.
//
// Reduced motion: when the user has `prefers-reduced-motion: reduce` set
// we skip the interval entirely and render a static "..." plus the
// sr-only label — no blinking, no cycling. The DOM contract is unchanged
// so the streaming pipeline can still remove the indicator by targeting
// `[data-thinking-indicator]`.
//
// Cleanup: `disconnect` always clears the interval. Turbo Drive
// navigations tear the element down and Stimulus fires `disconnect`, so
// no orphan timers survive a page change or a re-render.
export default class extends Controller {
  static targets = ["root"]
  static values = {
    interval: { type: Number, default: 400 },
    maxDots: { type: Number, default: 3 },
  }

  connect() {
    this.dotCount = 0
    this.render()

    const mq = typeof window.matchMedia === "function"
      ? window.matchMedia("(prefers-reduced-motion: reduce)")
      : null
    this.prefersReducedMotion = mq ? mq.matches : false

    if (this.prefersReducedMotion) {
      // Static 3-dot state; nothing to animate.
      this.dotCount = this.maxDotsValue
      this.render()
      return
    }

    this.timer = setInterval(() => {
      this.dotCount = (this.dotCount % this.maxDotsValue) + 1
      this.render()
    }, this.intervalValue)
  }

  disconnect() {
    this.stopTimer()
  }

  // Explicit stop hook so chat_controller can end the animation when the
  // first streaming chunk arrives, even before Turbo Stream replaces the
  // placeholder element.
  stop() {
    this.stopTimer()
    const el = this.rootTarget || this.element
    el.dataset.dotCount = "0"
    el.dataset.stopped = "true"
  }

  stopTimer() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  render() {
    const el = this.rootTarget || this.element
    el.dataset.dotCount = String(this.dotCount)
    const dots = el.querySelector(".thinking-dots")
    if (dots) dots.textContent = ".".repeat(this.dotCount)
  }
}
