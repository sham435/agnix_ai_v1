import { Controller } from "@hotwired/stimulus"

// Keeps the Model select in step with the Provider select on the agent form.
//
// Why: the form used to render every provider's models in one flat list, so a
// record could be saved as provider=google + model=claude-sonnet-4-6 - a pair
// no provider serves. The mistake only surfaced at run time, as a 404 from the
// upstream API. The catalog comes from Agent::MODELS (data-provider-models-
// models-value), so the browser can never offer a model the selected provider
// does not serve.
//
// Presentation only, and deliberately inert until the user changes provider:
// the server renders the already-scoped option list (including a saved model
// that is not in the catalog, e.g. an `ollama/local` tag), so this controller
// must not rebuild it on connect and drop that value.
export default class extends Controller {
  static targets = ["provider", "model"]
  static values = { models: Object }

  // Invoked by the Provider select (data-action="change->provider-models#sync").
  sync() {
    const models = this.modelsValue[this.providerTarget.value] || []
    if (models.length === 0) return

    const previous = this.modelTarget.value
    this.modelTarget.innerHTML = ""

    for (const name of models) {
      const option = document.createElement("option")
      option.value = name
      option.textContent = name
      this.modelTarget.appendChild(option)
    }

    // Keep the choice when the new provider serves it; otherwise land on that
    // provider's first model rather than leaving the select unselected.
    this.modelTarget.value = models.includes(previous) ? previous : models[0]
  }
}
