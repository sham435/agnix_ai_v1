import { Controller } from "@hotwired/stimulus"

// Phase 2e — toggles the schedule editor between "recurring" (cron) and
// "one_time" (a datetime picker), so only the relevant field is shown. Also
// shows a live plain-language preview of the cron while typing. Presentation
// only; the model still enforces "exactly one of cron/run_at" on submit.
export default class extends Controller {
  static targets = ["recurring", "oneTime", "scheduleType", "preview"]

  connect() {
    this.refresh()
  }

  // Invoked by radio change (data-action="change->scheduled-form#refresh").
  refresh() {
    const type = this.selectedType()
    if (this.hasRecurringTarget) this.recurringTarget.hidden = type !== "recurring"
    if (this.hasOneTimeTarget) this.oneTimeTarget.hidden = type !== "one_time"
    this.updatePreview()
  }

  // Invoked by cron input (data-action="input->scheduled-form#updatePreview").
  updatePreview() {
    if (!this.hasPreviewTarget) return
    const cron = this.data.get("cron") || ""
    const type = this.selectedType()
    if (type === "one_time") {
      this.previewTarget.textContent = "Runs once at the chosen time."
    } else if (cron.trim() === "") {
      this.previewTarget.textContent = "Enter a cron expression, e.g. 0 7 * * * for daily at 07:00."
    } else {
      this.previewTarget.textContent = `Schedule: ${cron.trim()} · ${this.timezone()}`
    }
  }

  selectedType() {
    const checked = this.scheduleTypeTargets.find((el) => el.checked)
    return checked ? checked.value : "recurring"
  }

  timezone() {
    const el = this.element.querySelector("#scheduled_task_timezone")
    return el ? el.value : "UTC"
  }
}
