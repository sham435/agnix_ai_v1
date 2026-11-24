import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["label", "list", "search", "status", "panel"]
  static values = { conversationId: String, default: "" }

  connect() {
    this._onDocClick = (e) => {
      if (this.panelTarget.hidden) return
      if (!this.element.contains(e.target)) this.close()
    }
    this._onKeydown = (e) => {
      if (e.key === "Escape" && !this.panelTarget.hidden) { e.preventDefault(); this.close() }
    }
    document.addEventListener("click", this._onDocClick)
    document.addEventListener("keydown", this._onKeydown)
    this.load()
  }
  disconnect() {
    this.abort?.abort()
    document.removeEventListener("click", this._onDocClick)
    document.removeEventListener("keydown", this._onKeydown)
  }

  toggle() {
    this.panelTarget.hidden = !this.panelTarget.hidden
    if (!this.panelTarget.hidden) this.searchTarget.focus()
  }
  close() { this.panelTarget.hidden = true }

  async load(refresh = false) {
    this.abort?.abort()
    this.abort = new AbortController()
    this.statusTarget.textContent = "Discovering models…"
    try {
      const query = new URLSearchParams()
      if (this.conversationIdValue) query.set("conversation_id", this.conversationIdValue)
      const response = await fetch(`/api/v1/models${refresh ? '/refresh' : ''}?${query}`, {
        method: refresh ? "POST" : "GET", credentials: "same-origin", signal: this.abort.signal,
        headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" }
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Model discovery failed.")
      this.catalogue = data
      this.render()
    } catch (error) {
      if (error.name !== "AbortError") this.statusTarget.textContent = error.message
    }
  }

  refresh() { this.load(true) }
  search() { this.render() }

  static READINESS = {
    billing_blocked: "billing blocked - provider credits are insufficient",
    inference_ready: "inference verified by a real request",
    catalogue_available: "catalogue discovered - model metadata found",
    connected: "credentials configured - no catalogue yet",
    access_restricted: "access restricted by provider policy",
    configuration_invalid: "connection configuration needs attention",
    disabled: "paused",
    unavailable: "unavailable"
  }

  providerStatus(provider) {
    return this.constructor.READINESS[provider.readiness] || provider.connection_status
  }

  modelStatus(model, provider) {
    if (model.availability_status === "access_restricted") return "access restricted"
    if (provider.readiness === "configuration_invalid") return "configuration invalid"
    const inference = {
      verified: "inference verified",
      billing_blocked: "billing blocked",
      failed: model.last_inference_error_code || "inference failed",
      unverified: "inference unverified"
    }[model.inference_status] || "inference unverified"
    const tools = model.supports_tools === true ? "tool support verified"
      : (model.supports_tools === false ? "tool support unavailable" : "tool support unverified")
    return `${model.api_family || "chat_completions"} · ${inference} · ${tools}`
  }

  render() {
    const data = this.catalogue
    if (!data) return
    const selected = data.selected_model
    const chosen = data.models.find(model => model.provider_id === selected?.provider_id && model.model_id === selected?.model_id)
    this.labelTarget.textContent = chosen?.display_name || (selected ? "Selected model unavailable" : "Agent assignment")
    this.listTarget.replaceChildren()
    const query = this.searchTarget.value.trim().toLowerCase()
    for (const provider of data.providers) {
      const models = data.models.filter(model => model.provider_id === provider.provider_id && `${model.display_name} ${model.model_id} ${model.provider_name} ${model.api_family}`.toLowerCase().includes(query))
      if (models.length === 0 && query) continue
      const details = document.createElement("details")
      const selectedInGroup = models.some(m => m === chosen)
      // Keep groups expanded by default so models stay clickable; users can
      // collapse a provider with its summary toggle to reduce visual noise.
      details.open = true
      const summary = document.createElement("summary")
      summary.className = "cursor-pointer text-xs font-semibold text-fg-subtle mt-2 mb-1 select-none"
      summary.textContent = `${provider.provider_name} · ${this.providerStatus(provider)}`
      details.append(summary)
      const group = document.createElement("div")
      group.className = "space-y-1"
      for (const model of models) {
        const button = document.createElement("button")
        button.type = "button"
        button.className = "block w-full text-left px-3 py-2 rounded-lg hover:bg-surface text-sm"
        button.disabled = model.availability_status !== "available"
        const active = chosen === model
        const capabilities = [model.supports_tools === true ? "Tools" : null, model.supports_vision === true ? "Vision" : null,
          model.supports_streaming === true ? "Streaming" : null].filter(Boolean)
        button.textContent = `${active ? 'Selected · ' : ''}${model.display_name} · ${model.local ? 'Local' : 'Cloud'} · ${this.modelStatus(model, provider)}${capabilities.length ? ' · ' + capabilities.join(', ') : ''}`
        button.setAttribute("aria-pressed", String(active))
        button.addEventListener("click", () => this.select({ provider_id: model.provider_id, model_id: model.model_id }))
        group.append(button)
      }
      details.append(group)
      this.listTarget.append(details)
    }
    const errors = data.providers.filter(provider => provider.error_code).map(provider => `${provider.provider_name}: ${provider.error_code}`)
    this.statusTarget.textContent = errors.join(" · ") || (data.models.length ? "Discovery does not verify inference." : "No available models.")
  }

  reset() { this.select({ use_organization_default: true }) }

  async select(selection) {
    if (this.saving) return
    this.saving = true
    try {
      const url = this.conversationIdValue
        ? `/api/v1/conversations/${encodeURIComponent(this.conversationIdValue)}/model`
        : "/api/v1/models/selection"
      const response = await fetch(url, {
        method: "PATCH", credentials: "same-origin",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
        body: JSON.stringify(this.conversationIdValue ? selection : { ...selection, scope: "user" })
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Could not select model.")
      this.catalogue = data
      this.render()
      this.panelTarget.hidden = true
    } catch (error) { this.statusTarget.textContent = error.message }
    finally { this.saving = false }
  }
}
