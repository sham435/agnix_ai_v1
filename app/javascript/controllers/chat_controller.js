import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

// Chat controller - handles streaming, message rendering, and auto-scroll.
export default class extends Controller {
  static targets = ["assistantMessage", "streamingContent"]

  connect() {
    this.subscribeToChannel()
    this.scrollToBottom()
  }

  subscribeToChannel() {
    const conversationId = this.element.dataset.conversationId
    if (!conversationId) return

    cable.subscribeTo(
      { channel: "ConversationChannel", conversation_id: conversationId },
      {
        received: (data) => this.handleStream(data),
        connected: () => console.log("Cable connected"),
        disconnected: () => console.log("Cable disconnected")
      }
    )
  }

  handleStream(data) {
    switch (data.type) {
      case "content":
        this.updateStreamingContent(data.content)
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

  updateStreamingContent(content) {
    const el = this.streamingContentTarget
    if (!el) return

    el.textContent = content
    el.classList.add("streaming-cursor")
    this.scrollToBottom()
  }

  showToolCall(tool, result) {
    // Could show a toast or inline notification.
    console.log("Tool call:", tool, result)
  }

  completeStreaming() {
    const el = this.streamingContentTarget
    if (el) {
      el.classList.remove("streaming-cursor")
    }
    // Reload to show the saved message.
    setTimeout(() => window.location.reload(), 500)
  }

  stopStreaming() {
    const el = this.streamingContentTarget
    if (el) {
      el.textContent += "\n\n[Generation stopped]"
      el.classList.remove("streaming-cursor")
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
      // Show brief confirmation.
      const btn = event.target.closest("button")
      if (btn) {
        btn.classList.add("text-emerald-400")
        setTimeout(() => btn.classList.remove("text-emerald-400"), 1000)
      }
    }
  }
}
