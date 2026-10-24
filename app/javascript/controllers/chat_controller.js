import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Chat controller — owns the Action Cable subscription for streaming
// tokens, keeps optimistic user bubbles in sync with server-rendered
// ones, removes the thinking indicator the instant real content lands,
// and pins scroll only when the user was already near the bottom (so
// scrolling up to re-read history is never hijacked).
//
// In-flight turn model:
//   The live tab optimistically creates an assistant "thinking" container
//   keyed by the composer's client_request_id (chat_input_controller). The
//   server then bridges that container to the real message id via an
//   `assistant_started` Action Cable frame and streams `status` /
//   `content_delta` / `completed` / `failed` frames tagged with BOTH the
//   request_id and message_id.
//
//   Every frame updates an authoritative in-memory turn buffer (keyed by
//   request_id, falling back to message_id). Rendering paints FROM the buffer
//   into whichever container is currently in the DOM. This makes the pipeline
//   immune to the two races that used to hide the indicator until refresh:
//     * a status/delta arriving before the container exists (was silently
//       dropped) — it now lives in the buffer and repaints on reconcile
//     * the racy Turbo Stream append vs the reliable Action Cable stream —
//       whichever container lands first is painted from the same buffer, so
//       exactly one assistant bubble ever shows and no token is lost.
export default class extends Controller {
  static targets = ["streamingContent"]

  // Distance from the bottom (in px) inside which we treat the viewport as
  // "at bottom" and keep pinning new content. Anything larger and we let
  // the user stay where they are.
  static SCROLL_PIN_THRESHOLD = 160

  connect() {
    this.turns = new Map() // key -> { key, rid, mid, text, phase, done, failed, error }
    this.subscribeToChannel()
    this.observeMessagesList()
    this.bindScrollTracking()
    // First paint on a loaded conversation should always show the newest
    // message; subsequent auto-pins honour the wasNearBottom flag.
    this.forceScrollToBottom()
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
    if (this.observer) {
      this.observer.disconnect()
      this.observer = null
    }
    if (this.scrollContainer && this.scrollHandler) {
      this.scrollContainer.removeEventListener("scroll", this.scrollHandler)
      this.scrollHandler = null
    }
    this.turns = new Map()
  }

  subscribeToChannel() {
    const conversationId = this.element.dataset.conversationId
    if (!conversationId) return

    this.subscription = cable.subscribeTo(
      { channel: "ConversationChannel", conversation_id: conversationId },
      {
        received: (data) => this.handleStream(data),
      }
    )
  }

  handleStream(data) {
    // Per-conversation isolation: a broadcast tagged for another
    // conversation must never touch this page's DOM. Both Turbo Stream and
    // Action Cable frames we consume carry conversation_id; when present we
    // require it to match this controller's own conversation.
    const own = this.element.dataset.conversationId
    if (data.conversation_id && own && String(data.conversation_id) !== String(own)) return

    switch (data.type) {
      case "assistant_started":
        this.onAssistantStarted(data)
        break
      case "status":
        this.setStatus(data.phase, data.message_id, data.error, data.request_id)
        break
      case "content_delta":
        this.appendContentDelta(data.text, data.message_id, data.request_id)
        break
      case "tool_call":
        this.showToolCall(data.tool, data.result, data.message_id, data.request_id)
        break
      case "completed":
        this.completeStreaming(data.message_id, data.request_id)
        break
      case "failed":
        this.failStreaming(data.message_id, data.message, data.request_id)
        break
      // Back-compat: legacy full-content frames still work if they arrive.
      case "content":
        this.replaceStreamingContent(data.content, data.message_id, data.request_id)
        break
      case "stopped":
        this.stopStreaming()
        break
    }
  }

  // ── Turn buffer ────────────────────────────────────────────────────────
  // Resolve (or create) the authoritative buffer for a run. Keyed by
  // request_id when present (stable across the optimistic → real transition),
  // otherwise by message_id. An already-buffered turn found by message_id is
  // re-keyed to the request_id so pre-`assistant_started` deltas merge in.
  turnFor(rid, mid) {
    let turn = null
    if (rid) turn = this.turns.get(rid) || null
    if (!turn && mid) {
      for (const t of this.turns.values()) {
        if (t.mid === mid) { turn = t; break }
      }
    }
    if (!turn) {
      const key = rid || mid
      if (!key) return null
      turn = { key, rid: rid || null, mid: mid || null, text: "", phase: null, done: false, failed: false, error: null }
      this.turns.set(key, turn)
    }
    if (rid && turn.key !== rid) {
      // Re-key from message_id to the more stable request_id.
      this.turns.delete(turn.key)
      turn.key = rid
      this.turns.set(rid, turn)
    }
    if (rid) turn.rid = rid
    if (mid && !turn.mid) turn.mid = mid
    return turn
  }

  // Find the container element currently in the DOM for a run. Prefers the
  // real server-rendered assistant (identified by request_id and carrying a
  // data-message-id), falls back to the composer's optimistic pending
  // container, then to a plain message-id lookup (server-only / reload case).
  resolveContainer(rid, mid) {
    const list = document.getElementById("messages-list") || document
    if (rid) {
      const real = list.querySelector(
        `[data-message-role="assistant"][data-request-id="${cssEscape(rid)}"]:not([data-assistant-pending])`
      )
      if (real) return real
      const pending = list.querySelector(`[data-assistant-pending][data-request-id="${cssEscape(rid)}"]`)
      if (pending) return pending
    }
    if (mid) {
      return list.querySelector(`[data-message-role="assistant"][data-message-id="${cssEscape(mid)}"]`)
    }
    return null
  }

  // Paint the buffer's accumulated text into whichever container currently
  // exists. Idempotent: repeated paints (e.g. after the optimistic container
  // is swapped for the real one) reproduce identical DOM. Silently no-ops when
  // no container exists yet — the next reconcile repaints.
  paint(turn) {
    if (!turn) return
    const container = this.resolveContainer(turn.rid, turn.mid)
    if (!container) return

    // Bridge the pending container to the real message id once known, so the
    // finalized Turbo replace and mid-targeted frames find it.
    if (turn.mid) {
      if (!container.getAttribute("data-message-id")) container.setAttribute("data-message-id", turn.mid)
      if (!container.id) container.id = `assistant-message-${turn.mid}`
      if (turn.rid && !container.getAttribute("data-request-id")) container.setAttribute("data-request-id", turn.rid)
    }

    const body = container.querySelector("[data-streaming-content]")
    if (body) {
      if (turn.mid) body.setAttribute("data-streaming-content", turn.mid)
      if (body.textContent !== turn.text) body.textContent = turn.text
    }

    // Drive the collapsible trace if the container carries one.
    const trace = this.traceController(turn.rid, turn.mid)
    if (trace && turn.phase) trace.setPhase(turn.phase)

    if (turn.text) this.removeThinkingIndicator(turn.rid, turn.mid)
    if (turn.done) this.teardownIndicator(turn.rid, turn.mid)
  }

  // The assistant response exists server-side before its first status frame.
  // Retarget the optimistic container to the real message id so subsequent
  // mid-keyed frames and the final Turbo replace resolve it.
  onAssistantStarted(data) {
    const turn = this.turnFor(data.request_id, data.message_id)
    if (!turn) return
    turn.streamStartedAt = data.stream_started_at || turn.streamStartedAt
    this.paint(turn)
  }

  // ── Execution trace ──────────────────────────────────────────────────
  // Resolve the collapsible execution-trace controller nested inside the
  // assistant bubble for a given run (null once the placeholder has been
  // replaced by the final render).
  traceController(rid, mid) {
    const wrapper = this.resolveContainer(rid, mid)
    if (!wrapper) return null
    const traceEl = wrapper.querySelector("[data-execution-trace]")
    if (!traceEl) return null
    return this.application?.getControllerForElementAndIdentifier
      ? this.application.getControllerForElementAndIdentifier(traceEl, "execution-trace")
      : null
  }

  setStatus(phase, messageId, error, rid) {
    const turn = this.turnFor(rid, messageId)
    // Keep the dots alive during connecting/thinking; the trace controller
    // handles retiring them the moment we reach generating/completed/failed.
    if (phase === "failed") {
      this.failStreaming(messageId, error, rid)
      return
    }
    if (turn) turn.phase = phase === "completed" ? "completed" : phase
    const trace = this.traceController(rid, messageId)
    if (trace) {
      trace.setPhase(phase)
    } else if (phase === "generating" || phase === "completed") {
      // Trace already gone (message finalized) — just make sure dots are dead.
      this.removeThinkingIndicator(rid, messageId)
    }
    if (turn) this.paint(turn)
    if (phase === "completed") this.completeStreaming(messageId, rid)
  }

  appendContentDelta(text, messageId, rid) {
    if (text == null || text === "") return
    const turn = this.turnFor(rid, messageId)

    // First genuine token — retire the animated indicator.
    this.removeThinkingIndicator(rid, messageId)

    if (turn) {
      turn.text += text
      if (!turn.phase || turn.phase === "connecting" || turn.phase === "thinking") turn.phase = "generating"
      this.paint(turn)
    } else {
      // Fallback (no turn possible): append directly to the streaming body.
      const el = document.querySelector(
        messageId ? `[data-streaming-content="${messageId}"]` : "[data-streaming-content]"
      )
      if (el) el.insertAdjacentHTML("beforeend", escapeHtml(text))
    }
    const trace = this.traceController(rid, messageId)
    if (trace) trace.setPhase("generating")
    this.scrollToBottomIfPinned()
  }

  // Legacy path retained so any in-flight full-content frames still render.
  replaceStreamingContent(content, messageId, rid) {
    const turn = this.turnFor(rid, messageId)
    if (turn) { turn.text = content || ""; this.paint(turn) }
    const el = document.querySelector(
      messageId ? `[data-streaming-content="${messageId}"]` : "[data-streaming-content]"
    )
    if (!el) return
    if (content && content.length > 0) this.removeThinkingIndicator(rid, messageId)
    el.innerHTML = escapeHtml(content)
    this.scrollToBottomIfPinned()
  }

  removeThinkingIndicator(rid, messageId) {
    // The indicator is a sibling of the streaming body within the same
    // assistant message wrapper. Scope the query so a stale indicator in
    // another message can't be removed by mistake.
    const wrapper = this.resolveContainer(rid, messageId)
    if (!wrapper) return
    this.destroyIndicators(wrapper)
    // Clear the data-streaming flag now that content is on screen.
    wrapper.dataset.streaming = "false"
  }

  teardownIndicator(rid, messageId) {
    const wrapper = this.resolveContainer(rid, messageId) || document
    this.destroyIndicators(wrapper)
  }

  destroyIndicators(scope) {
    scope.querySelectorAll("[data-thinking-indicator]").forEach((node) => {
      const ctrl = this.application?.getControllerForElementAndIdentifier
        ? this.application.getControllerForElementAndIdentifier(node, "thinking-indicator")
        : null
      if (ctrl && typeof ctrl.stop === "function") ctrl.stop()
      node.remove()
    })
  }

  showToolCall(tool, result, messageId, rid) {
    // Surface tool activity in the collapsible trace — never as raw content
    // and never the model's private reasoning.
    const trace = this.traceController(rid, messageId)
    if (trace) {
      trace.noteTool(tool?.name || tool)
    } else {
      console.log("Tool call:", tool, result)
    }
  }

  completeStreaming(messageId, rid) {
    const turn = this.turnFor(rid, messageId)
    if (turn) { turn.done = true; if (!turn.phase) turn.phase = "completed" }
    const trace = this.traceController(rid, messageId)
    if (trace) trace.finish()
    // Remove any lingering indicator(s) — scoped to this message when we have
    // an id, otherwise sweep globally as a safety net for the finalized turn.
    const scope = this.resolveContainer(rid, messageId) || document
    this.destroyIndicators(scope)
    this.scrollToBottomIfPinned()
    // Release the composer's generation guard for this run.
    this.broadcastTerminal("completed", rid, messageId)
  }

  failStreaming(messageId, message, rid) {
    // Provider/connection failure: stop the dots, mark the trace failed, and
    // leave a clear (non-fake) signal. The red error bubble is appended via a
    // separate Turbo Stream frame.
    const turn = this.turnFor(rid, messageId)
    if (turn) { turn.failed = true; turn.done = true; turn.phase = "failed"; turn.error = message }
    const trace = this.traceController(rid, messageId)
    if (trace) trace.fail(message)
    const scope = this.resolveContainer(rid, messageId) || document
    this.destroyIndicators(scope)
    // Release the composer's generation guard for this run.
    this.broadcastTerminal("failed", rid, messageId)
  }

  // Tell the composer the run reached a terminal state so its guard can free
  // the Send control (matching request_id when known).
  broadcastTerminal(kind, rid, messageId) {
    this.element.dispatchEvent(new CustomEvent("assistant:terminal", {
      bubbles: true,
      detail: { kind, request_id: rid, message_id: messageId }
    }))
  }

  stopStreaming() {
    const el = document.querySelector("[data-streaming-content]")
    if (el) {
      el.textContent += "\n\n[Generation stopped]"
    }
    this.destroyIndicators(document)
  }

  // ── Scroll pinning ─────────────────────────────────────────────────────
  // We track whether the user was near the bottom before new content
  // arrived, and only auto-scroll if so. A user reading older messages
  // will never have their viewport yanked back down.
  bindScrollTracking() {
    this.scrollContainer = document.getElementById("messages-container")
    if (!this.scrollContainer) return

    this.wasNearBottom = true
    this.scrollHandler = () => {
      this.wasNearBottom = this.isNearBottom()
    }
    this.scrollContainer.addEventListener("scroll", this.scrollHandler, { passive: true })
  }

  isNearBottom() {
    const el = this.scrollContainer
    if (!el) return true
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight
    return distance <= this.constructor.SCROLL_PIN_THRESHOLD
  }

  forceScrollToBottom() {
    const container = document.getElementById("messages-container")
    if (container) container.scrollTop = container.scrollHeight
    this.wasNearBottom = true
  }

  scrollToBottomIfPinned() {
    if (this.wasNearBottom) this.forceScrollToBottom()
  }

  // Retained for backwards compat with the pre-refactor callers.
  scrollToBottom() {
    this.forceScrollToBottom()
  }

  // ── Optimistic-bubble / container reconciliation ──────────────────────
  // chat_input_controller.js renders a placeholder user bubble AND a
  // placeholder assistant "thinking" container, both tagged with a
  // client_request_id. When the reconciled server broadcast (same id) lands via
  // Turbo Stream, we delete the local copy so the DOM holds exactly one of
  // each, and repaint the buffered assistant text into the surviving container.
  observeMessagesList() {
    const list = document.getElementById("messages-list")
    if (!list) return

    this.observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        for (const node of m.addedNodes) {
          if (!(node instanceof HTMLElement)) continue
          this.reconcileOptimistic(node)
        }
      }
    })
    this.observer.observe(list, { childList: true })
  }

  reconcileOptimistic(addedNode) {
    // 1. Server user bubbles carry both data-user-message and
    //    data-client-request-id. Remove every optimistic placeholder carrying
    //    the same id so the thread shows exactly one user message per send.
    const serverBubble = addedNode.matches?.("[data-user-message][data-client-request-id]")
      ? addedNode
      : addedNode.querySelector?.("[data-user-message][data-client-request-id]")
    if (serverBubble) {
      const cid = serverBubble.getAttribute("data-client-request-id")
      if (cid) {
        const list = document.getElementById("messages-list") || document
        list.querySelectorAll(
          `[data-optimistic-user][data-client-request-id="${cssEscape(cid)}"]`
        ).forEach((d) => d.remove())
      }
    }

    // 2. Real assistant streaming container (carries data-request-id and a
    //    data-message-id). Adopt it: drop the optimistic pending container for
    //    the same run and repaint buffered text into the surviving element, so
    //    there is exactly ONE visible thinking indicator per run.
    //
    //    IMPORTANT: the selector must EXCLUDE [data-assistant-pending]. The
    //    moment chat_input appends the optimistic container, this very observer
    //    fires for that mutation; if it matched, the pending node would delete
    //    itself and the "thinking" indicator would never appear without a
    //    refresh — the exact defect this guards against. Only a genuine server
    //    container (no pending flag) is allowed to retire the optimistic copy.
    const assistantEl = addedNode.matches?.('[data-message-role="assistant"][data-request-id]:not([data-assistant-pending])')
      ? addedNode
      : addedNode.querySelector?.('[data-message-role="assistant"][data-request-id]:not([data-assistant-pending])')
    if (assistantEl) {
      const rid = assistantEl.getAttribute("data-request-id")
      if (!rid) return
      const mid = assistantEl.getAttribute("data-message-id")
      const turn = this.turnFor(rid, mid)
      const list = document.getElementById("messages-list") || document
      list.querySelectorAll(`[data-assistant-pending][data-request-id="${cssEscape(rid)}"]`)
        .forEach((d) => d.remove())
      // Repaint buffered content into the adopted real container.
      if (turn) { if (mid) turn.mid = mid; this.paint(turn) }
    }
  }

  // ── Interaction handlers (unchanged) ─────────────────────────────────
  copy(event) {
    const btn = event.currentTarget
    const messageEl = btn.closest("[data-chat-target=assistantMessage]")
    if (!messageEl) return

    const content = messageEl.querySelector(".markdown-body")?.textContent
    if (content) {
      navigator.clipboard.writeText(content).then(() => this.flashCopy(btn))
    }
  }

  copyCode(event) {
    const btn = event.currentTarget
    const pre = btn.closest(".code-block")?.querySelector(".code-pre")
    if (!pre) return

    navigator.clipboard.writeText(pre.textContent).then(() => this.flashCopy(btn))
  }

  regenerate(event) {
    const btn = event.currentTarget
    btn.dataset.state = "loading"
    btn.classList.add("animate-spin", "pointer-events-none", "text-emerald-400")
    this.element.dispatchEvent(new CustomEvent("agent:regenerate", { bubbles: true }))
  }

  goodResponse(event) {
    const btn = event.currentTarget
    this.flashCopy(btn, "text-emerald-400")
  }

  flashCopy(el, className = "text-emerald-400") {
    el.classList.add(className)
    setTimeout(() => el.classList.remove(className), 1200)
  }
}

function escapeHtml(str) {
  return String(str)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
}

function cssEscape(value) {
  if (typeof CSS !== "undefined" && CSS.escape) return CSS.escape(value)
  // Fallback for environments without CSS.escape (older Safari, JSDOM).
  return String(value).replace(/[^a-zA-Z0-9_-]/g, (c) => "\\" + c)
}
