import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["approveBtn", "interruptBtn"]

  approve(event) {
    const runId = event.params.agentRunId || event.target.dataset.agentRunId
    if (!runId) return
    this._post(`/agent_runs/${runId}/resume`)
  }

  resume(event) {
    const runId = event.params.agentRunId || event.target.dataset.agentRunId
    if (!runId) return
    this._post(`/agent_runs/${runId}/resume`)
  }

  interrupt(event) {
    const form = event.target.closest("form") || event.target.closest("[data-turbo-method]")
    if (form) return

    fetch(event.target.dataset.url || "/interrupt", {
      method: "POST",
      headers: { "X-CSRF-Token": document.querySelector("[name='csrf-token']").content }
    }).then(() => {
      window.location.reload()
    })
  }

  _post(url) {
    fetch(url, {
      method: "POST",
      headers: {
        "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
        "Accept": "text/vnd.turbo-stream.html"
      }
    }).then(() => {
      window.location.reload()
    })
  }
}
