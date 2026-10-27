import { Controller } from "@hotwired/stimulus"

// Submits the surrounding form as soon as the control changes, so a one-field
// settings select (an agent's model, a member's role) saves without a button.
//
// Why a controller and not an inline `onchange="this.form.requestSubmit()"`:
// the app sets a CSP nonce for script-src, and per CSP3 a present nonce makes
// 'unsafe-inline' moot - for inline <script> tags AND for event handler
// attributes. The attribute stayed in the DOM, Chrome refused to run it, and the
// select looked like it did nothing (development hides this because
// content_security_policy_report_only is on there). Module code loaded from
// 'self' is allowed, so the same call from here runs in every environment.
export default class extends Controller {
  // Wired by the control itself: data-action="change->auto-submit#submit".
  submit() {
    const form = this.element.form || this.element.closest("form")
    if (!form) return

    // requestSubmit() fires the submit event (so Turbo handles it); form.submit()
    // would bypass both Turbo and any before-submit listener.
    if (typeof form.requestSubmit === "function") {
      form.requestSubmit()
    } else {
      form.submit()
    }
  }
}
