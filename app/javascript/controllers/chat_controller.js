import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["streamingContent"]

  connect() {
    this.subscribeToChannel()
    this.scrollToBottom()
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
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
    switch (data.type) {
      case "content":
        this.updateStreamingContent(data.content, data.message_id)
        break
      case "tool_call":
        this.showToolCall(data.tool, data.result)
        break
      case "complete":
        this.completeStreaming()
        break
      case "stopped":
        this.stopStreaming()
        break
    }
  }

  updateStreamingContent(content, messageId) {
    const selector = `[data-streaming-content="${messageId}"]`
    const el = document.querySelector(selector)
    if (!el) return

    el.textContent = content
    this.scrollToBottom()
  }

  showToolCall(tool, result) {
    console.log("Tool call:", tool, result)
  }

  completeStreaming() {
    // Turbo Stream broadcast_replace handles the final render.
    this.scrollToBottom()
  }

  stopStreaming() {
    const el = document.querySelector("[data-streaming-content]")
    if (el) {
      el.textContent += "\n\n[Generation stopped]"
    }
  }

  scrollToBottom() {
    const container = document.getElementById("messages-container")
    if (container) {
      container.scrollTop = container.scrollHeight
    }
  }

  copy(event) {
    const messageEl = event.target.closest("[data-chat-target]")?.parentElement?.parentElement
    if (!messageEl) return

    const content = messageEl.querySelector(".prose, .markdown-body")?.textContent
    if (content) {
      navigator.clipboard.writeText(content)
      const btn = event.target.closest("button")
      if (btn) {
        btn.classList.add("text-emerald-400")
        setTimeout(() => btn.classList.remove("text-emerald-400"), 1000)
      }
    }
  }
}
