import { Controller } from "@hotwired/stimulus"

// Composer behaviour: Enter sends, Shift+Enter inserts a newline, IME-safe.
// Event listeners are attached directly in connect() (not via data-action) so
// binding never depends on Stimulus re-discovering re-rendered descendants
// after the composer is refreshed by a Turbo Stream response.
//
// Attachments: uploads go through the canonical asset pipeline
// (POST /api/v1/assets, X-CSRF-Token from the layout meta tag). Uploaded bytes
// land in Active Storage behind an Asset row; "Add from Library" references an
// existing asset id directly — selecting a Library file never re-uploads it.
export default class extends Controller {
  static targets = ["input", "hint", "fileInput", "chips", "libraryPanel", "libraryItems", "libraryEmpty", "librarySearch", "libraryPreview", "libraryPreviewTitle", "libraryPreviewBody", "send"]

  // In-flight submission guard. Distinct from the short HTTP round trip:
  //   submitting  — the POST is in flight
  //   running     — the message saved + job enqueued; the assistant response
  //                 (possibly a long agent run) is being generated
  // The guard frees the Send control only on a matching terminal event
  // (completed/failed) or a watchdog timeout, never leaving the composer
  // permanently locked after a navigation, provider failure, or lost job.
  static SUBMIT_TIMEOUT_MS = 15000
  static GENERATION_TIMEOUT_MS = 130000

  connect() {
    this._submitState = "idle"
    this._activeRunId = null
    this._submitTimer = null
    this._genTimer = null
    this._lastLineCount = 1
    this._lastHintAt = 0
    this._uploadSeq = 0
    this._pollTimers = {}
    this._libraryPollTimers = {} // assetId -> interval while extraction is pending
    this._librarySearchTimer = null
    this._libraryQuery = ""
    this.attachments = new Map() // key -> { name, size, assetId?, status, progress?, error? }
    if (this.hasChipsTarget) this.renderChips()

    this.hintSeen = localStorage.getItem("chat_hint_seen") === "1"
    if (this.hintSeen) this.hideHint(false)

    if (this.hasInputTarget) {
      this._onKeydown = this.keydown.bind(this)
      this._onInput = this.autosize.bind(this)
      this._onPaste = this.paste.bind(this)
      this.inputTarget.addEventListener("keydown", this._onKeydown)
      this.inputTarget.addEventListener("input", this._onInput)
      this.inputTarget.addEventListener("paste", this._onPaste)
      this.autosize()
    }
    if (this.hasFileInputTarget) {
      this._onChange = this.fileSelected.bind(this)
      this.fileInputTarget.addEventListener("change", this._onChange)
      // A stale (pre-upgrade) page snapshot can resurrect the legacy
      // message[files] direct-upload input; stripping its name stops it from
      // double-submitting multipart data that the server now rejects.
      this.fileInputTarget.removeAttribute("name")
    }
    this._dragging = false
    this._onDragOver = (e) => { e.preventDefault(); this._dragging = true; this.element.classList.add("border-emerald-500/40") }
    this._onDragLeave = () => { this._dragging = false; this.element.classList.remove("border-emerald-500/40") }
    this._onDrop = (e) => {
      e.preventDefault()
      this._dragging = false
      this.element.classList.remove("border-emerald-500/40")
      if (e.dataTransfer?.files?.length) this.addFiles(e.dataTransfer.files)
    }
    this.element.addEventListener("dragover", this._onDragOver)
    this.element.addEventListener("dragleave", this._onDragLeave)
    this.element.addEventListener("drop", this._onDrop)
    this._onLibraryClick = this.onLibraryListClick.bind(this)
    if (this.hasLibraryItemsTarget) {
      this.libraryItemsTarget.addEventListener("click", this._onLibraryClick)
    }
    this._onDocClick = this.handleDocClick.bind(this)
    document.addEventListener("click", this._onDocClick)
    // The form submit may come from the button (no keydown guard runs), so
    // block sends while uploads are still in flight at the event level too.
    this._onFormSubmit = (e) => this.handleSubmit(e)
    this.element.addEventListener("submit", this._onFormSubmit)
    // chat_controller dispatches this the moment a run reaches a terminal
    // Action Cable frame (completed/failed) — the only legitimate signal to
    // release the generation guard.
    this._onAssistantTerminal = (e) => this.handleAssistantTerminal(e.detail)
    document.addEventListener("assistant:terminal", this._onAssistantTerminal)
    // Refresh-safe composer: layers the server-side draft rows back onto the
    // chips panel after a Turbo reload — no re-upload, no lost selections.
    this.restoreDrafts()
    // A successful submit re-renders this composer, creating a fresh controller
    // instance. The guard therefore lives on the stable #messages-container
    // host, not on `this` — re-adopt it so a still-running send keeps Send
    // disabled across that re-render.
    this.syncGuardFromHost()
  }

  // The stable host element that outlives composer re-renders.
  composerHost() {
    return document.getElementById("messages-container")
  }

  // The correlation id of a run whose guard is currently held, if any.
  hostBusyRun() {
    return this.composerHost()?.dataset.composerBusy || ""
  }

  markHostBusy(rid) {
    const host = this.composerHost()
    if (host && rid) host.dataset.composerBusy = rid
  }

  clearHostBusy(rid) {
    const host = this.composerHost()
    if (!host) return
    if (!rid || host.dataset.composerBusy === rid) delete host.dataset.composerBusy
  }

  // Re-adopt an in-flight run after the composer was re-rendered.
  syncGuardFromHost() {
    const rid = this.hostBusyRun()
    if (rid) {
      this._activeRunId = rid
      this.setSubmitState("running")
      this.armGenerationWatchdog()
    } else {
      this.setSubmitState("idle")
    }
  }

  armGenerationWatchdog() {
    clearTimeout(this._genTimer)
    this._genTimer = setTimeout(() => {
      // The run never produced a terminal frame (lost job / hung provider).
      // Fail open: free the guard. The stale-run timeout on the server keeps
      // the persisted placeholder honest on the next refresh.
      if (this.hostBusyRun()) this.releaseGuard("generation_timeout", this._activeRunId)
    }, this.constructor.GENERATION_TIMEOUT_MS)
  }

  disconnect() {
    if (this.hasInputTarget && this._onKeydown) {
      this.inputTarget.removeEventListener("keydown", this._onKeydown)
      this.inputTarget.removeEventListener("input", this._onInput)
      this.inputTarget.removeEventListener("paste", this._onPaste)
    }
    if (this.hasFileInputTarget && this._onChange) {
      this.fileInputTarget.removeEventListener("change", this._onChange)
    }
    if (this._onDragOver) {
      this.element.removeEventListener("dragover", this._onDragOver)
      this.element.removeEventListener("dragleave", this._onDragLeave)
      this.element.removeEventListener("drop", this._onDrop)
    }
    if (this.hasLibraryItemsTarget && this._onLibraryClick) {
      this.libraryItemsTarget.removeEventListener("click", this._onLibraryClick)
    }
    if (this._onDocClick) document.removeEventListener("click", this._onDocClick)
    if (this._onFormSubmit) this.element.removeEventListener("submit", this._onFormSubmit)
    if (this._onAssistantTerminal) document.removeEventListener("assistant:terminal", this._onAssistantTerminal)
    if (this._submitTimer) { clearTimeout(this._submitTimer); this._submitTimer = null }
    if (this._genTimer) { clearTimeout(this._genTimer); this._genTimer = null }
    Object.values(this._pollTimers).forEach((t) => clearInterval(t))
    Object.values(this._libraryPollTimers || {}).forEach((t) => clearInterval(t))
    if (this._librarySearchTimer) clearTimeout(this._librarySearchTimer)
  }

  keydown(e) {
    // Never submit while an IME (Chinese/Japanese/Korean) composition is open:
    // the Enter that commits the candidate must not send the message.
    if (e.isComposing || e.keyCode === 229) return

    const isEnter = e.key === "Enter"
    if (!isEnter) return

    const platform = this.constructor.platformOf()
    const hasModifier = e.metaKey || e.ctrlKey
    const shouldSubmit = (() => {
      // §6 policy:
      //   macOS  — Cmd+Enter submits; bare Enter + Shift+Enter insert newlines
      //            so multi-line prompts stay editable.
      //   mobile — bare Enter (keyboard Send) submits; Shift+Enter newline.
      //            Cmd/Ctrl+Enter also submits as a desktop-parity fallback.
      //   other  — bare Enter submits; Shift+Enter newline;
      //            Cmd/Ctrl+Enter also submits (matches the visible ⌘↵/Ctrl↵
      //            hint on the composer).
      if (platform === "mac") return e.metaKey && !e.shiftKey
      if (platform === "mobile") return !e.shiftKey
      // Desktop Windows/Linux: bare Enter or Cmd/Ctrl+Enter both send;
      // Shift+Enter always inserts a newline.
      return !e.shiftKey
    })()

    if (!shouldSubmit) return

    e.preventDefault()
    if (!this.hasInputTarget || this.inputTarget.value.trim() === "") return
    // Ignore duplicate submissions while the same run is in flight.
    if (this.isBusy()) return
    // Never submit while an upload is still in flight: the message would
    // go out without the attachment. The hint explains why nothing sent.
    if (this.uploadInProgress()) { this.showTempHint(); return }
    if (typeof this.element.requestSubmit === "function") {
      this.element.requestSubmit()
    } else {
      this.element.submit()
    }
    // Suppress the unused-var lint hint while making the modifier logic readable.
    void hasModifier
  }

  // §6: platform classification used by both keydown() and the visible hint.
  // Prefer the modern `navigator.userAgentData.platform` when present, fall
  // back to `navigator.platform` / `navigator.userAgent`, then to a coarse
  // pointer + touch heuristic for mobile. Exposed as a static method so specs
  // can stub it in a headless browser and assert the exact submit combo
  // without faking a real device.
  static platformOf() {
    if (this._platformCache && (Date.now() - this._platformCache.at) < 60_000) {
      return this._platformCache.value
    }
    const nav = typeof navigator !== "undefined" ? navigator : {}
    const uaData = nav.userAgentData
    const coarsePointer = typeof window !== "undefined"
      && typeof window.matchMedia === "function"
      && window.matchMedia("(pointer: coarse)").matches
    const hasTouch = (nav.maxTouchPoints || 0) > 0
    let token = ""
    if (uaData && typeof uaData.platform === "string") token = uaData.platform
    else if (typeof nav.platform === "string") token = nav.platform
    else if (typeof nav.userAgent === "string") token = nav.userAgent

    // Detect phones/tablets before Mac, since iPhone/iPad UA strings do NOT
    // contain "Mac" but a coarse pointer with touch is the honest signal.
    const looksMobile = /Android|iPhone|iPad|iPod|Mobile|Silk/i.test(token)
      || (coarsePointer && hasTouch)
    const looksMac = /Mac|iPhone|iPad|iPod/i.test(token)

    let value
    if (looksMobile) value = "mobile"
    else if (looksMac) value = "mac"
    else value = "desktop"

    this._platformCache = { value, at: Date.now() }
    return value
  }

  // True while a submission or its async generation is in flight. Consults the
  // persistent host flag so the guard survives a composer re-render.
  isBusy() {
    return this._submitState === "submitting"
      || this._submitState === "running"
      || !!this.hostBusyRun()
  }

  // True when the composer holds no sendable text. Drives the Send button's
  // idle disabled state (disabled while empty, live once there is text).
  inputIsEmpty() {
    return !this.hasInputTarget || this.inputTarget.value.trim() === ""
  }

  uploadInProgress() {
    return Array.from(this.attachments.values()).some((a) => a.status === "uploading")
  }

  // -- Submit pipeline (optimistic render + client_request_id) --------------
  //
  // Flow:
  //   1. Upload-in-flight guard (unchanged): refuse to send while any
  //      attachment is uploading so the message never omits a chip.
  //   2. Generate a UUID (crypto.randomUUID with a Math.random fallback)
  //      and inject it as a hidden `message[client_request_id]` input so
  //      the server can persist it into `message.metadata`.
  //   3. Render an optimistic user bubble in `#messages-list` marked with
  //      `data-optimistic-user` + `data-client-request-id`. chat_controller
  //      removes it the moment the reconciled server bubble with the same
  //      id arrives via Turbo Stream — exactly one DOM bubble per send.
  //   4. Preserve text + chips on failure: `clear(event)` already inspects
  //      `turbo:submit-end` and skips clearing when the submission failed.
  //      On failure we also drop the optimistic bubble so the composer and
  //      the thread visually agree.
  handleSubmit(e) {
    // Duplicate-protection: a second click / Enter while submitting or running
    // is ignored at the controller level (the backend also dedupes by
    // client_request_id, so retries never create a second message or job).
    if (this.isBusy()) {
      e.preventDefault()
      return
    }
    if (this.uploadInProgress()) {
      e.preventDefault()
      this.showTempHint()
      return
    }
    // Empty composer is a no-op — mirrors keydown guard for button clicks.
    if (!this.hasInputTarget || this.inputTarget.value.trim() === "") {
      e.preventDefault()
      return
    }

    const cid = this.ensureClientRequestId()
    // Carry the per-conversation draft token so the server can consume the
    // exact attachment-draft rows this send delivers. Without it the drafts
    // linger for 24h and restoreDrafts() resurrects chips for files that were
    // already sent. Injected into the form synchronously (this is the submit
    // listener) so Turbo serializes it with the rest of the fields.
    this.ensureDraftTokenField()
    this._pendingRequestId = cid
    this._activeRunId = cid
    this.markHostBusy(cid)
    this.setSubmitState("submitting")
    this.renderOptimisticBubble(cid)
    // Own the assistant "thinking" container client-side the instant we
    // submit, so the live page never waits on the (racy) server append or a
    // page refresh to show that the assistant is working. Keyed by the same
    // request_id the server echoes back, so it merges with the real bubble.
    this.renderOptimisticAssistant(cid)

    // Safety net: if the HTTP round trip never resolves cleanly, release the
    // submitting guard (fail-open) so the composer is never permanently locked.
    clearTimeout(this._submitTimer)
    this._submitTimer = setTimeout(() => {
      if (this._submitState === "submitting") this.releaseGuard("timeout")
    }, this.constructor.SUBMIT_TIMEOUT_MS)
  }

  // ── In-flight guard state machine ──────────────────────────────────────
  setSubmitState(next) {
    this._submitState = next
    const btn = this.hasSendTarget ? this.sendTarget : this.element.querySelector('button[type="submit"]')
    if (btn) {
      // Disable Send only while a submission/generation is in flight. The
      // textarea is left fully editable so the draft can still be modified.
      if (next === "submitting" || next === "running") {
        btn.disabled = true
        btn.setAttribute("aria-disabled", "true")
        btn.dataset.submitState = next
      } else {
        // Idle: disabled only while the composer is empty. The send-target /
        // submit button lights up the moment there is real text.
        const empty = this.inputIsEmpty()
        btn.disabled = empty
        if (empty) btn.setAttribute("aria-disabled", "true")
        else btn.removeAttribute("aria-disabled")
        btn.dataset.submitState = "idle"
      }
    }
  }

  // Release the guard on a matching terminal event, a failure, or a timeout.
  // `reason` is informational; the generation watchdog and terminal frames
  // both route through here so the state can never desync.
  releaseGuard(reason, rid) {
    if (rid && this._activeRunId && rid !== this._activeRunId && reason !== "generation_timeout") return
    clearTimeout(this._submitTimer); this._submitTimer = null
    clearTimeout(this._genTimer); this._genTimer = null
    this.clearHostBusy(rid || this._activeRunId)
    this._activeRunId = null
    this.setSubmitState("idle")
  }

  // Called by chat_controller when an Action Cable frame marks the run done.
  handleAssistantTerminal(detail) {
    const rid = detail?.request_id
    // Free the guard only for the run we're currently tracking (or if we never
    // captured an id, accept any terminal to avoid a stuck composer).
    if (rid && this._activeRunId && rid !== this._activeRunId) return
    this.releaseGuard(detail?.kind || "terminal", rid || this._activeRunId)
  }

  // Optimistic assistant "thinking" container — the browser-owned counterpart
  // to the server placeholder. Mirrors the streaming markup so the
  // execution-trace and thinking-indicator Stimulus controllers attach to it
  // exactly as they do to a server-rendered bubble.
  renderOptimisticAssistant(clientRequestId) {
    const list = document.getElementById("messages-list")
    if (!list) return

    // Never stack duplicates for the same correlation id.
    list.querySelectorAll(`[data-assistant-pending][data-request-id="${cssEscape(clientRequestId)}"]`)
      .forEach((n) => n.remove())

    const node = document.createElement("div")
    node.className = "group/message relative isolate"
    node.setAttribute("data-assistant-pending", "true")
    node.setAttribute("data-request-id", clientRequestId)
    node.setAttribute("data-message-role", "assistant")
    node.setAttribute("data-streaming", "true")
    // Absolute start stamp so the DOM sweep can retire this optimistic
    // container even if Action Cable never bridges a single frame (e.g. the
    // job was enqueued but its worker died before broadcasting
    // assistant_started). Mirrors the server-rendered placeholder contract.
    node.setAttribute("data-stream-started-at", new Date().toISOString())
    node.innerHTML = `
      <div class="flex gap-3.5">
        <div class="shrink-0 mt-1">
          <div class="size-8 rounded-xl bg-gradient-to-br from-emerald-500/25 to-emerald-700/15 border border-emerald-500/25 grid place-items-center shadow-lg shadow-emerald-950/30">
            <svg class="size-4 text-accent-text" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83"/></svg>
          </div>
        </div>
        <div class="flex-1 min-w-0">
          <div class="mt-2.5">
            <div class="thinking-ack" data-thinking-ack>Your valuable input is received</div>
            <div data-execution-trace class="execution-trace" data-controller="execution-trace">
              <button type="button" class="execution-trace__summary" data-execution-trace-target="summary" data-action="execution-trace#toggle" aria-expanded="false">
                <span data-thinking-indicator class="thinking-indicator" data-controller="thinking-indicator" data-thinking-indicator-target="root" data-dot-count="0" role="status" aria-live="polite" aria-atomic="true">
                  <span class="thinking-dots" aria-hidden="true"></span>
                  <span class="sr-only">Shams AI is thinking</span>
                </span>
                <span class="execution-trace__phase" data-execution-trace-target="phase">Shams AI is thinking</span>
                <svg class="execution-trace__chevron" data-execution-trace-target="chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="m6 9 6 6 6-6"/></svg>
              </button>
              <ol class="execution-trace__log" data-execution-trace-target="log" hidden></ol>
            </div>
            <div class="mt-2 text-fg whitespace-pre-wrap break-words text-[16.5px] leading-[1.8] font-[450] tracking-[0.006em]"
                 data-streaming-content="pending-${clientRequestId}"></div>
          </div>
        </div>
      </div>`
    list.appendChild(node)

    const container = document.getElementById("messages-container")
    if (container) container.scrollTop = container.scrollHeight
  }

  removeOptimisticAssistant(clientRequestId) {
    if (!clientRequestId) return
    const list = document.getElementById("messages-list")
    if (!list) return
    list.querySelectorAll(`[data-assistant-pending][data-request-id="${cssEscape(clientRequestId)}"]`)
      .forEach((n) => n.remove())
  }

  ensureDraftTokenField() {
    let hidden = this.element.querySelector('input[type="hidden"][name="message[attachment_draft_token]"]')
    if (!hidden) {
      hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = "message[attachment_draft_token]"
      this.element.appendChild(hidden)
    }
    hidden.value = this.draftToken()
    return hidden.value
  }

  ensureClientRequestId() {
    // Reuse the id if a re-rendered composer already has one — a submit
    // interrupted by an error and retried keeps the same correlation so
    // the previous optimistic copy is deduped too.
    let hidden = this.element.querySelector('input[type="hidden"][name="message[client_request_id]"]')
    if (hidden && hidden.value) return hidden.value

    const value = (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function")
      ? crypto.randomUUID()
      : `req-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`

    if (!hidden) {
      hidden = document.createElement("input")
      hidden.type = "hidden"
      hidden.name = "message[client_request_id]"
      this.element.appendChild(hidden)
    }
    hidden.value = value
    return value
  }

  renderOptimisticBubble(clientRequestId) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const content = this.hasInputTarget ? this.inputTarget.value : ""
    const attachmentNames = Array.from(this.attachments.values())
      .filter((a) => a.status === "ready" && a.assetId)
      .map((a) => a.name)

    // Remove any stale optimistic copy from a previous failed send carrying
    // the same correlation id — rapid retries should never stack bubbles.
    list.querySelectorAll(`[data-optimistic-user][data-client-request-id="${cssEscape(clientRequestId)}"]`)
      .forEach((n) => n.remove())

    const bubble = document.createElement("div")
    bubble.className = "flex gap-3.5 group/message justify-end"
    bubble.setAttribute("data-optimistic-user", "true")
    bubble.setAttribute("data-client-request-id", clientRequestId)
    bubble.setAttribute("data-message-role", "user")

    const nameRing = (document.querySelector("meta[name='current-user-initial']")?.content || "U").slice(0, 1).toUpperCase()
    const chipsHtml = attachmentNames.length
      ? `<div class="mt-2 mb-0.5 flex flex-wrap justify-end gap-2 max-w-[85%]">
           ${attachmentNames.map((n) => `<span class="inline-flex items-center gap-1.5 rounded-lg border border-border bg-panel px-2 py-1 text-[11.5px] text-fg-muted">${escapeHtml(n)}</span>`).join("")}
         </div>`
      : ""

    bubble.innerHTML = `
      <div class="flex-1 min-w-0 flex flex-col items-end">
        <div class="flex items-center gap-2">
          <span class="text-[13px] font-semibold text-fg">You</span>
          <span class="size-1 rounded-full bg-border"></span>
          <span class="text-[11px] text-fg-muted" data-optimistic-time>just now</span>
        </div>
        ${chipsHtml}
        <div class="mt-2 max-w-[85%] rounded-2xl rounded-tr-md bg-elevated border border-border px-4 py-3 text-[15px] leading-[1.75] text-fg whitespace-pre-wrap break-words" data-optimistic-body></div>
      </div>
      <div class="size-8 rounded-full bg-gradient-to-br from-emerald-400 to-emerald-600 grid place-items-center text-[11px] font-bold text-black shrink-0 mt-1 shadow-lg shadow-emerald-950/40">${escapeHtml(nameRing)}</div>
    `
    // Use textContent so user-typed angle brackets / markup cannot inject.
    const body = bubble.querySelector("[data-optimistic-body]")
    if (body) body.textContent = content

    list.appendChild(bubble)

    // Keep the newest message visible. chat_controller owns the scroll
    // policy; a fresh user send always pins to bottom.
    const container = document.getElementById("messages-container")
    if (container) container.scrollTop = container.scrollHeight
  }

  removeOptimisticBubble(clientRequestId) {
    if (!clientRequestId) return
    const list = document.getElementById("messages-list")
    if (!list) return
    list.querySelectorAll(`[data-optimistic-user][data-client-request-id="${cssEscape(clientRequestId)}"]`)
      .forEach((n) => n.remove())
  }

  paste(e) {
    const text = (e.clipboardData || window.clipboardData).getData("text")
    if (text && text.includes("\n")) {
      this.showTempHint()
    }
  }

  attach() {
    if (this.hasFileInputTarget) this.fileInputTarget.click()
  }

  fileSelected(e) {
    this.addFiles(e.target.files)
    e.target.value = ""
  }

  addFiles(files) {
    if (this.attachments.size >= 8) return
    Array.from(files || []).slice(0, 8 - this.attachments.size)
      .filter((f) => f.size > 0 && f.size <= 26_214_400)
      .forEach((file) => this.uploadOne(file))
  }

  // -- Upload through the canonical asset pipeline ----------------------------

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  uploadOne(file) {
    const tempKey = `local-${++this._uploadSeq}`
    this.attachments.set(tempKey, { name: file.name, size: file.size, status: "uploading", progress: 0 })
    this.renderChips()

    const body = new FormData()
    body.append("file", file)

    const xhr = new XMLHttpRequest()
    xhr.open("POST", "/api/v1/assets")
    xhr.setRequestHeader("X-CSRF-Token", this.csrfToken())
    xhr.setRequestHeader("Accept", "application/json")

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && this.attachments.has(tempKey)) {
        const entry = this.attachments.get(tempKey)
        entry.progress = Math.round((e.loaded / e.total) * 100)
        this.renderChips()
      }
    }
    xhr.onload = () => this.uploadFinished(tempKey, file, xhr)
    xhr.onerror = () => {
      this.attachments.set(tempKey, { name: file.name, size: file.size, status: "error", error: "network_error" })
      this.renderChips()
    }
    xhr.send(body)
  }

  uploadFinished(tempKey, file, xhr) {
    if (!this.attachments.has(tempKey) || this.attachments.get(tempKey).removed) return

    if (xhr.status !== 200 && xhr.status !== 201) {
      let code = "upload_failed"
      try { code = JSON.parse(xhr.responseText).error_code || code } catch (_e) { /* keep generic */ }
      this.attachments.set(tempKey, { name: file.name, size: file.size, status: "error", error: code })
      this.renderChips()
      return
    }

    let asset = {}
    let extraction = {}
    try {
      const json = JSON.parse(xhr.responseText)
      asset = json.asset || {}
      extraction = json.extraction || {}
    } catch (_e) { /* fall through to ready state */ }

    const entry = {
      name: file.name, size: file.size, assetId: asset.id,
      status: "ready", extractionStatus: extraction.status || null,
      extractionError: extraction.error_code || null, extractionMeta: extraction
    }
    this.attachments.set(tempKey, entry)
    this.renderChips()

    this.persistDraft(asset.id, entry.name)
    if (["pending", "processing"].includes(extraction.status)) {
      this.pollExtraction(tempKey, asset.id)
    }
  }

  pollExtraction(tempKey, assetId) {
    let attempts = 0
    const timer = setInterval(async () => {
      attempts += 1
      if (attempts > 10 || !this.attachments.has(tempKey)) {
        clearInterval(timer)
        delete this._pollTimers[tempKey]
        return
      }
      const res = await fetch(`/api/v1/assets/${assetId}`, { headers: { Accept: "application/json" } })
      if (!res.ok) return
      const json = await res.json()
      const st = json.extraction?.status
      if (["completed", "failed", "canceled"].includes(st)) {
        const entry = this.attachments.get(tempKey)
        if (entry) {
          entry.extractionStatus = st
          entry.extractionError = json.extraction?.error_code
          entry.extractionMeta = json.extraction || {}
          this.renderChips()
        }
        clearInterval(timer)
        delete this._pollTimers[tempKey]
      }
    }, 1500)
    this._pollTimers[tempKey] = timer
  }

  // -- Library ------------------------------------------------------------------
  // The Library lists every asset the user has ever uploaded (auto-provisioned
  // on ingest). Picking a row references its existing asset id — never a second
  // upload. Search filters server-side; each row can be previewed; rows whose
  // text extraction is still running poll to a terminal state so the badge and
  // preview become accurate without a manual refresh.

  async library() {
    if (!this.hasLibraryPanelTarget) return
    const panel = this.libraryPanelTarget

    // Toggle: clicking the Library button again closes the panel.
    if (!panel.classList.contains("hidden")) {
      this.libraryClose()
      return
    }

    panel.classList.remove("hidden")
    this.librarySearchTarget?.focus()
    await this.loadLibrary()
  }

  libraryClose() {
    this.libraryPanelTarget?.classList.add("hidden")
    this.libraryPreviewClose()
    Object.values(this._libraryPollTimers || {}).forEach((t) => clearInterval(t))
    this._libraryPollTimers = {}
  }

  // Fetch + render the (optionally filtered) library.
  async loadLibrary() {
    if (!this.hasLibraryItemsTarget) return
    this.libraryItemsTarget.textContent = ""
    this.libraryItemsTarget.innerHTML = '<div class="px-3 py-4 text-[12px] text-fg-muted">Loading…</div>'
    try {
      const q = this._libraryQuery ? `?q=${encodeURIComponent(this._libraryQuery)}` : ""
      const res = await fetch(`/api/v1/library${q}`, { headers: { Accept: "application/json" } })
      const items = res.ok ? (await res.json()).items || [] : []
      this.renderLibrary(items)
    } catch (_e) {
      this.libraryItemsTarget.innerHTML = '<div class="px-3 py-4 text-[12px] text-red-600 dark:text-red-400">Couldn\'t load library — try again.</div>'
    }
  }

  // Debounced search box -> server-side filter.
  librarySearch(_event) {
    if (!this.hasLibrarySearchTarget) return
    clearTimeout(this._librarySearchTimer)
    this._librarySearchTimer = setTimeout(() => {
      this._libraryQuery = this.librarySearchTarget.value.trim()
      this.loadLibrary()
    }, 260)
  }

  renderLibrary(items) {
    if (!this.hasLibraryItemsTarget) return
    this.libraryPreviewClose()
    if (!items.length) {
      this.libraryItemsTarget.innerHTML = ""
      this.libraryEmptyTarget?.classList.remove("hidden")
      if (this._libraryQuery) {
        this.libraryEmptyTarget.textContent = `No files match “${this._libraryQuery}”.`
      } else {
        this.libraryEmptyTarget.textContent = "No files yet. Upload something first."
      }
      return
    }
    this.libraryEmptyTarget?.classList.add("hidden")

    this.libraryItemsTarget.innerHTML = items.map((item) => {
      const st = item.extraction_status
      const badge = `<span data-lib-status-for="${escapeHtml(item.asset_id)}" class="${libStatusClass(st)}">${libStatusText(st)}</span>`
      return `
      <div class="flex items-center gap-2 px-2 py-2 rounded-lg hover:bg-hover border-b border-border transition">
        <span data-library-icon="${escapeHtml(item.category || "")}" class="text-fg-muted text-[13px] shrink-0">${libraryIcon(item.category)}</span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[13px] text-fg">${escapeHtml(item.label || "file")}</span>
          <span class="block text-[10.5px] text-fg-subtle">${formatBytes(item.byte_size || 0)} · ${badge}</span>
        </span>
        <button type="button" title="Preview" aria-label="Preview"
          data-preview-id="${escapeHtml(item.asset_id)}"
          data-preview-label="${escapeHtml(item.label || "file")}"
          class="grid size-7 place-items-center rounded-md text-fg-subtle hover:text-fg hover:bg-hover transition shrink-0">
          <svg class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z"/><circle cx="12" cy="12" r="3"/></svg>
        </button>
        <button type="button"
          data-asset-id="${escapeHtml(item.asset_id)}"
          data-label="${escapeHtml(item.label || "")}"
          data-size="${item.byte_size || 0}"
          data-category="${escapeHtml(item.category || "")}"
          class="px-2.5 py-1 rounded-md text-[11.5px] font-medium bg-emerald-500/15 text-emerald-700 dark:text-emerald-300 hover:bg-emerald-500/25 border border-emerald-500/25 transition shrink-0">
          Add
        </button>
      </div>`
    }).join("")

    // Poll any row still extracting so its badge + preview settle without a refresh.
    items.filter((i) => ["pending", "processing"].includes(i.extraction_status))
      .forEach((i) => this.pollLibraryExtraction(i.asset_id))
  }

  // Delegated list click: preview button vs add button.
  onLibraryListClick(e) {
    const previewBtn = e.target.closest("[data-preview-id]")
    if (previewBtn) { this.libraryPreview(previewBtn); return }
    const addBtn = e.target.closest("[data-asset-id]")
    if (addBtn) { this.libraryPick(addBtn) }
  }

  libraryPick(button) {
    const assetId = button.dataset.assetId
    if (!assetId || this.attachments.has(assetId)) return

    // Library reuse: reference the existing asset, never re-upload bytes.
    this.attachments.set(assetId, {
      name: button.dataset.label || "file", size: parseInt(button.dataset.size || "0", 10),
      assetId: assetId, status: "ready", fromLibrary: true
    })
    this.libraryPanelTarget?.classList.add("hidden")
    this.renderChips()

    this.persistDraft(assetId, button.dataset.label)
  }

  // -- Library preview ----------------------------------------------------------

  async libraryPreview(button) {
    if (!this.hasLibraryPreviewTarget) return
    const assetId = button.dataset.previewId
    if (!assetId) return
    this._previewAssetId = assetId

    this.libraryPreviewTarget.classList.remove("hidden")
    if (this.hasLibraryPreviewTitleTarget) this.libraryPreviewTitleTarget.textContent = button.dataset.previewLabel || "Preview"
    if (this.hasLibraryPreviewBodyTarget) this.libraryPreviewBodyTarget.innerHTML = '<div class="text-[12px] text-fg-muted">Loading…</div>'

    try {
      const res = await fetch(`/api/v1/assets/${encodeURIComponent(assetId)}/preview`, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error("preview failed")
      // Ignore a stale response if the user switched rows mid-flight.
      if (this._previewAssetId !== assetId) return
      this.renderPreview(await res.json())
    } catch (_e) {
      if (this.hasLibraryPreviewBodyTarget) this.libraryPreviewBodyTarget.innerHTML = '<div class="text-[12px] text-red-600 dark:text-red-400">Couldn\'t load preview.</div>'
    }
  }

  renderPreview(data) {
    const body = this.libraryPreviewBodyTarget
    if (!body) return
    const a = data.asset || {}
    const x = data.extraction || {}
    if (this.hasLibraryPreviewTitleTarget) this.libraryPreviewTitleTarget.textContent = a.filename || "Preview"
    body.innerHTML = ""

    if (a.image && a.download_url) {
      const img = document.createElement("img")
      img.src = a.download_url
      img.alt = a.filename || ""
      img.className = "max-h-40 w-auto rounded-lg border border-border"
      body.appendChild(img)
      return
    }

    if (["pending", "processing"].includes(x.status)) {
      body.innerHTML = '<div class="text-[12px] text-amber-700 dark:text-amber-300/90">Extracting text… this preview updates once it\'s ready.</div>'
      return
    }
    if (x.status === "failed") {
      body.innerHTML = `<div class="text-[12px] text-amber-600 dark:text-amber-400/90">${escapeHtml(friendlyExtractionError(x.error_code))}</div>`
      return
    }

    const text = (x.preview || "").trim()
    if (!text) {
      body.innerHTML = '<div class="text-[12px] text-fg-muted">No text preview available.</div>'
      return
    }
    const pre = document.createElement("pre")
    pre.className = "whitespace-pre-wrap break-words text-[11.5px] leading-relaxed text-fg-muted max-h-40 overflow-auto"
    pre.textContent = text
    body.appendChild(pre)
    if (x.truncated) {
      const note = document.createElement("div")
      note.className = "mt-1.5 text-[10.5px] text-fg-subtle"
      note.textContent = "Showing a preview of the extracted text."
      body.appendChild(note)
    }
  }

  libraryPreviewClose() {
    this._previewAssetId = null
    this.libraryPreviewTarget?.classList.add("hidden")
    if (this.hasLibraryPreviewBodyTarget) this.libraryPreviewBodyTarget.innerHTML = ""
  }

  // Poll a single library row's extraction until terminal, then update its
  // badge in place (no full re-render, so the search box keeps focus).
  pollLibraryExtraction(assetId) {
    if (!assetId || this._libraryPollTimers[assetId]) return
    let attempts = 0
    const timer = setInterval(async () => {
      attempts += 1
      if (attempts > 20 || !this._libraryPollTimers[assetId]) {
        clearInterval(timer); delete this._libraryPollTimers[assetId]; return
      }
      try {
        const res = await fetch(`/api/v1/assets/${encodeURIComponent(assetId)}`, { headers: { Accept: "application/json" } })
        if (!res.ok) return
        const json = await res.json()
        const st = json.extraction?.status
        if (["completed", "failed", "canceled"].includes(st)) {
          this.updateLibraryRowStatus(assetId, st)
          clearInterval(timer); delete this._libraryPollTimers[assetId]
          // If this row's preview is open, refresh it now that text is ready.
          if (st === "completed" && this._previewAssetId === assetId) {
            const btn = this.libraryItemsTarget?.querySelector(`[data-preview-id="${cssEscape(assetId)}"]`)
            if (btn) this.libraryPreview(btn)
          }
        }
      } catch (_e) { /* transient poll errors are ignored */ }
    }, 2000)
    this._libraryPollTimers[assetId] = timer
  }

  updateLibraryRowStatus(assetId, status) {
    const badge = this.libraryItemsTarget?.querySelector(`[data-lib-status-for="${cssEscape(assetId)}"]`)
    if (!badge) return
    badge.className = libStatusClass(status)
    badge.textContent = libStatusText(status)
  }

  // -- Server-backed attachment drafts -----------------------------------------
  // Uploads/library picks persist a row keyed by a per-conversation draft
  // token (localStorage), so a refreshed page restores its chips through
  // GET /api/v1/attachment_drafts without re-uploading. All best-effort:
  // fetch failures never block composing.

  draftToken() {
    const match = window.location.pathname.match(/conversations\/([0-9a-f-]{36})/)
    const scope = match ? match[1] : "global"
    const storageKey = `shams_draft_token_${scope}`

    let token = localStorage.getItem(storageKey)
    if (!token) {
      token = (window.crypto && typeof crypto.randomUUID === "function")
        ? crypto.randomUUID()
        : `d-${Date.now()}-${Math.random().toString(16).slice(2)}`
      try { localStorage.setItem(storageKey, token) } catch (_e) { /* private mode: drafts just degrade */ }
    }
    return token
  }

  async persistDraft(assetId, label) {
    if (!assetId) return
    try {
      const res = await fetch("/api/v1/attachment_drafts", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ draft_token: this.draftToken(), asset_id: assetId, label: label || null })
      })
      if (!res.ok) return

      const json = await res.json()
      const entry = Array.from(this.attachments.values()).find((a) => a.assetId === assetId)
      if (entry && json.draft) entry.draftRowId = json.draft.id
    } catch (_e) { /* best-effort */ }
  }

  async restoreDrafts() {
    const token = this.draftToken()
    if (!token) return
    try {
      const url = `/api/v1/attachment_drafts?draft_token=${encodeURIComponent(token)}`
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (!res.ok) return

      const json = await res.json()
      ;(json.drafts || []).forEach((draft) => {
        if (!draft.asset_id || this.attachments.has(draft.asset_id)) return
        this.attachments.set(draft.asset_id, {
          name: draft.label || draft.filename || "file",
          size: parseInt(draft.byte_size || "0", 10),
          assetId: draft.asset_id, status: "ready", fromDraft: true, draftRowId: draft.id,
          extractionStatus: draft.extraction_status || null
        })
      })
      this.renderChips()
    } catch (_e) { /* best-effort restore */ }
  }

  // Click anywhere outside the composer closes the library panel.
  handleDocClick(e) {
    const panel = this.libraryPanelTarget
    if (!panel || panel.classList.contains("hidden")) return
    if (!this.element.contains(e.target)) panel.classList.add("hidden")
  }

  async remove(e) {
    const key = e.currentTarget.dataset.key
    const entry = this.attachments.get(key)
    if (entry) entry.removed = true
    this.attachments.delete(key)
    this.renderChips()

    // Drop the server-side draft row too, so a later send cannot resurrect
    // a chip the user removed (best-effort: errors are ignored).
    if (entry && entry.draftRowId) {
      const token = this.draftToken()
      try {
        const url = `/api/v1/attachment_drafts/${encodeURIComponent(entry.draftRowId)}?draft_token=${encodeURIComponent(token)}`
        await fetch(url, { method: "DELETE" })
      } catch (_e) { /* best-effort */ }
    }
  }

  // -- Rendering ---------------------------------------------------------------

  renderChips() {
    if (!this.hasChipsTarget) return
    const chips = Array.from(this.attachments.entries()).map(([key, a]) => this.chipHtml(key, a)).join("")
    this.chipsTarget.innerHTML = chips
  }

  chipHtml(key, a) {
    const hidden = a.assetId && a.status === "ready"
      ? `<input type="hidden" name="message[attachment_asset_ids][]" value="${a.assetId}">`
      : ""

    let state = ""
    if (a.status === "uploading") {
      state = `<div class="h-1 w-full rounded-full bg-border overflow-hidden"><div class="h-full bg-emerald-500/80" style="width:${a.progress || 0}%"></div></div>`
    } else if (a.status === "error") {
      state = `<span class="text-[10px] text-red-600 dark:text-red-400">${friendlyUploadError(a.error)}</span>`
    } else if (a.extractionStatus === "failed") {
      state = `<span class="text-[10px] text-amber-600 dark:text-amber-400/90">${friendlyExtractionError(a.extractionError)}</span>`
    }

    return `
      <div class="flex items-center gap-2 rounded-lg border border-border bg-panel px-2 py-1.5">
        ${hidden}
        <span class="text-fg-muted text-[13px] shrink-0">${libraryIcon(a.status === "error" ? "" : "*", true)}</span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[12px] text-fg">${escapeHtml(a.name || "file")}</span>
          ${state}
        </span>
        <button type="button" data-key="${key}" data-action="chat-input#remove"
          class="grid size-5 place-items-center rounded text-fg-subtle hover:text-fg hover:bg-hover transition shrink-0"
          title="Remove">✕</button>
      </div>`
  }

  // -- Autosize & hint ---------------------------------------------------------

  autosize() {
    if (!this.hasInputTarget) return
    const el = this.inputTarget
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
    this.checkMultiline()
    // Keep the Send control in sync with the draft while idle (empty -> off).
    if (this._submitState === "idle") this.setSubmitState("idle")
  }

  checkMultiline() {
    if (!this.hasInputTarget) return
    const lines = this.inputTarget.value.split("\n").length
    const now = Date.now()
    if (lines >= 3 && this._lastLineCount < 3 && now - this._lastHintAt > 10000) {
      this.showTempHint()
      this._lastHintAt = now
    }
    this._lastLineCount = lines
  }

  clear(event) {
    // Failed submits keep the composer intact: Turbo fires submit-end even
    // on a 422, and clearing there would silently destroy the user's typed
    // text (and any not-yet-delivered attachment chips). Both shapes are
    // covered — submit-end detail exposes `formSubmission` whose result is
    // { success, ... } (Turbo >=7.1) or `succeeded` on newer builds.
    // Untargeted events (e.g. agent:generated) carry no submission and clear.
    const submission = event?.detail?.formSubmission
    const failed = submission && (submission.succeeded === false || submission.result?.success === false)
    if (failed) {
      // Optimistic bubble no longer reflects reality — drop it so the
      // composer and the thread visually agree, and free the correlation
      // id so a retry can generate a fresh one.
      this.removeOptimisticBubble(this._pendingRequestId)
      // A rejected send has no run — retire the assistant placeholder too and
      // release the submitting guard so the user can immediately retry. The
      // typed draft + chips are preserved (we never clear them on failure).
      this.removeOptimisticAssistant(this._pendingRequestId)
      this.releaseGuard("submit_failed", this._pendingRequestId)
      const hidden = this.element.querySelector('input[type="hidden"][name="message[client_request_id]"]')
      if (hidden) hidden.value = ""
      this._pendingRequestId = null
      return
    }

    // Success: the message is persisted and the run is enqueued. Move to the
    // running guard — Send stays disabled while the assistant generates, but
    // the draft textarea remains editable. The host flag keeps this true even
    // after the composer form itself is re-rendered by the Turbo response.
    clearTimeout(this._submitTimer); this._submitTimer = null
    if (this._activeRunId) {
      this.setSubmitState("running")
      this.armGenerationWatchdog()
    }

    // Success path: leave the optimistic bubble in place. The server does NOT
    // append the user message from this HTTP response (AgentStreamJob
    // broadcasts it first on the ordered pipeline, asynchronously). If we
    // removed the optimistic copy here the message would visibly vanish until
    // the job lands, then reappear — the "delayed user message" flicker.
    // Instead chat_controller's MutationObserver deletes the optimistic copy
    // the exact moment the reconciled server bubble (same client_request_id)
    // is appended, so there is always exactly one user bubble on screen with
    // no gap. We only drop our local correlation so the NEXT send gets a
    // fresh id; we never touch the DOM bubble.
    this._pendingRequestId = null
    const hidden = this.element.querySelector('input[type="hidden"][name="message[client_request_id]"]')
    if (hidden) hidden.value = ""

    // Turbo fires this after the submit response: detach chips that have been
    // delivered to the message (completed uploads with an asset id).
    Array.from(this.attachments.entries())
      .filter(([, a]) => a.status === "ready" && a.assetId)
      .forEach(([key]) => this.attachments.delete(key))
    if (this.hasChipsTarget) this.renderChips()

    if (this.hasInputTarget) {
      this.inputTarget.value = ""
      this.autosize()
      this.inputTarget.focus()
    }
    this.hideHint(true)
    this._lastLineCount = 1
  }

  // Composer "+" hook → create a scheduled task pre-filled with the current
  // message text (server-side prefills the prompt from ?prompt=). The chat text
  // stays put so a cancelled automation flow loses nothing.
  scheduleTask(event) {
    event?.preventDefault?.()
    const content = this.hasInputTarget ? this.inputTarget.value.trim() : ""
    const url = `/scheduled/new${content ? `?prompt=${encodeURIComponent(content)}` : ""}`
    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.assign(url)
    }
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

function escapeHtml(value) {
  const div = document.createElement("textarea")
  div.textContent = value == null ? "" : String(value)
  return div.innerHTML.replace(/"/g, "&quot;")
}

function formatBytes(bytes) {
  if (!bytes || bytes <= 0) return ""
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function libraryIcon(category) {
  if (category === "image") return "🖼"
  if (category === "document") return "📄"
  if (category === "spreadsheet") return "📊"
  if (category === "data") return "🧮"
  return "📄"
}

// Extraction-status badge for a Library row.
function libStatusText(status) {
  switch (status) {
    case "pending": return "queued"
    case "processing": return "extracting…"
    case "completed": return "ready"
    case "failed": return "unreadable"
    case "canceled": return "canceled"
    default: return "ready"
  }
}

function libStatusClass(status) {
  const base = "text-[10px]"
  switch (status) {
    case "pending":
    case "processing":
      return `${base} text-amber-600 dark:text-amber-400/90`
    case "failed":
    case "canceled":
      return `${base} text-red-600 dark:text-red-400/90`
    default:
      return `${base} text-emerald-600 dark:text-emerald-400/80`
  }
}

function friendlyUploadError(code) {
  const map = {
    unsupported_type: "Unsupported file type",
    mime_mismatch: "File content doesn't match its type",
    executable_forbidden: "Executable files aren't allowed",
    too_large: "Too large (25 MB max, 10 MB images)",
    empty_file: "File is empty",
    file_missing: "Upload failed — try again",
    network_error: "Connection failed — try again",
    upload_failed: "Upload failed — try again"
  }
  return map[code] || "Upload failed"
}

function friendlyExtractionError(code) {
  const map = {
    unsupported_format: "Can't read this format",
    malformed_archive: "Corrupted archive",
    corrupt_document: "Corrupted document",
    parse_error: "Couldn't parse",
    ocr_unavailable: "Scanned image — text extraction unavailable",
    content_too_large: "Too large to extract",
    extraction_error: "Extraction failed"
  }
  return map[code] || "Extraction failed"
}

function cssEscape(value) {
  if (typeof CSS !== "undefined" && CSS.escape) return CSS.escape(value)
  return String(value).replace(/[^a-zA-Z0-9_-]/g, (c) => "\\" + c)
}
