class AgentStreamJob < ApplicationJob
  queue_as :agents

  def perform(conversation_id:, user_id:, message_content: nil, channel: :web, phone_number: nil, resume_agent_run_id: nil)
    conversation = Conversation.find(conversation_id)
    user = User.find(user_id)
    agent = conversation.agent

    Rails.logger.info "[AgentStreamJob] START conversation=#{conversation_id} user=#{user_id}#{" resume_run=#{resume_agent_run_id}" if resume_agent_run_id}"

    # Create the streaming message immediately and broadcast it with cursor.
    streaming_msg = conversation.messages.create!(role: "assistant", content: ".")
    broadcast_append(conversation, streaming_msg, streaming: true)

    runner = AgentRunner.new(
      agent: agent,
      conversation: conversation,
      user: user,
      streaming_message: streaming_msg
    )

    if resume_agent_run_id
      agent_run = AgentRun.find(resume_agent_run_id)
      runner.resume_plan(agent_run, stream: true) do |chunk|
        broadcast_chunk(conversation, streaming_msg.id, chunk)
      end
    else
      runner.run(message_content, stream: true) do |chunk|
        broadcast_chunk(conversation, streaming_msg.id, chunk)
      end
    end

    Rails.logger.info "[AgentStreamJob] DONE conversation=#{conversation_id}"

    # Replace streaming message with final rendered version (no cursor).
    broadcast_replace(conversation, streaming_msg.reload, streaming: false)

    ActionCable.server.broadcast("conversation:#{conversation.id}", { type: "complete" })

    if channel == :whatsapp && phone_number
      last_message = conversation.messages.where(role: "assistant").last
      WhatsappService.send_message(phone_number, last_message.content) if last_message
    end
  rescue => e
    Rails.logger.error "[AgentStreamJob] ERROR conversation=#{conversation_id} #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n") if e.backtrace

    Turbo::StreamsChannel.broadcast_append_to(
      conversation,
      target: "messages-list",
      html: %(<div class="text-red-400 text-sm p-3 rounded-lg border border-red-500/20 bg-red-500/5">Agent error: #{ERB::Util.html_escape(e.message)}</div>)
    )

    ActionCable.server.broadcast("conversation:#{conversation.id}", { type: "stopped" })

    AgentAutoFixer.new(error: e, backtrace: e.backtrace.to_a, conversation: conversation).call
  end

  private

  def broadcast_append(conversation, message, streaming:)
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: message, streaming: streaming })
    Turbo::StreamsChannel.broadcast_append_to(conversation, target: "messages-list", html: html)
  end

  def broadcast_replace(conversation, message, streaming:)
    html = ApplicationController.render(partial: "messages/assistant_message", locals: { message: message, streaming: streaming })
    Turbo::StreamsChannel.broadcast_replace_to(conversation, target: "assistant-message-#{message.id}", html: html)
  end

  def broadcast_chunk(conversation, message_id, chunk)
    case chunk[:type]
    when "chunk"
      ActionCable.server.broadcast(
        "conversation:#{conversation.id}",
        { type: "content", content: chunk[:content], message_id: message_id }
      )
    when "tool_call"
      ActionCable.server.broadcast(
        "conversation:#{conversation.id}",
        { type: "tool_call", tool: chunk[:tool], result: chunk[:result], message_id: message_id }
      )
    end
  end
end
