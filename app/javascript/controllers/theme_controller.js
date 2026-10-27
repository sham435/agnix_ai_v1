import { Controller } from "@hotwired/stimulus"

// Phase 1b — theme system.
//
// The authoritative theme state lives on <html data-theme="dark|light">, set
// before first paint by an inline head script (no flash of the wrong theme).
// This controller only *changes* it: flip the attribute, persist the choice in
// localStorage (per-device, instant), and PATCH it to the server so it follows
// the user across devices. Tailwind v4 tokens flip automatically because every
// surface references var(--color-canvas) etc.
const STORAGE_KEY = "shams.theme"
const VALID = ["dark", "light"]

export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    // Belt-and-suspenders: the inline head script normally applies the stored
    // theme before first paint. If it ever fails to run, re-resolve here so a
    // returning user's chosen theme still wins over the HTML default.
    const resolved = this.resolveStored()
    if (resolved && resolved !== this.current()) {
      document.documentElement.setAttribute("data-theme", resolved)
      document.documentElement.classList.toggle("dark", resolved === "dark")
      this.updateMetaThemeColor(resolved)
    }
    this.sync()
  }

  // localStorage (per-device) -> explicit server preference -> null (stay dark).
  // No OS hint: the chat app is refined-dark by default and only an explicit
  // user choice selects the light theme (mirrors the head script exactly).
  resolveStored() {
    let stored = null
    try { stored = localStorage.getItem(STORAGE_KEY) } catch (_e) { /* private mode */ }
    if (VALID.includes(stored)) return stored
    const server = document.documentElement.getAttribute("data-server-theme")
    if (VALID.includes(server)) return server
    return null
  }

  // Flip dark <-> light. Wired from any [data-action="click->theme#toggle"].
  toggle() {
    const next = this.current() === "light" ? "dark" : "light"
    this.apply(next, { persist: true })
  }

  apply(theme, { persist = false } = {}) {
    if (!VALID.includes(theme)) return
    document.documentElement.setAttribute("data-theme", theme)
    document.documentElement.classList.toggle("dark", theme === "dark")
    this.updateMetaThemeColor(theme)
    if (persist) {
      try { localStorage.setItem(STORAGE_KEY, theme) } catch (_e) { /* private mode */ }
      this.saveToServer(theme)
    }
    this.sync()
  }

  current() {
    return document.documentElement.getAttribute("data-theme") || "dark"
  }

  // Reflect state onto the toggle button (icon swap + accessible label).
  sync() {
    const light = this.current() === "light"
    this.toggleTargets.forEach((btn) => {
      btn.setAttribute("aria-pressed", String(!light))
      const label = light ? "Switch to dark theme" : "Switch to light theme"
      btn.setAttribute("aria-label", label)
      btn.setAttribute("title", label)
      const sun = btn.querySelector("[data-theme-sun]")
      const moon = btn.querySelector("[data-theme-moon]")
      if (sun) sun.classList.toggle("hidden", light)
      if (moon) moon.classList.toggle("hidden", !light)
    })
  }

  updateMetaThemeColor(theme) {
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta) meta.setAttribute("content", theme === "light" ? "#ffffff" : "#0b0d10")
  }

  async saveToServer(theme) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      await fetch("/settings/theme", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          ...(token ? { "X-CSRF-Token": token } : {})
        },
        body: JSON.stringify({ ui_theme: theme })
      })
    } catch (_e) {
      // Best-effort: the localStorage preference already applied instantly and
      // will retry persisting on the next toggle. Never block the UI.
    }
  }
}
