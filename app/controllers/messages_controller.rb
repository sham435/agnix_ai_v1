class MessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation

  def create
    @message = @conversation.messages.build(
      role: "user",
      content: message_params[:content]
    )
    @message.pending_attachment_asset_ids = message_params[:attachment_asset_ids]
    # Client-generated correlation id — the composer tags its optimistic
    # bubble with the same value and removes it once the reconciled server
    # broadcast lands. Prevents duplicate user bubbles without a second
    # round trip.
    client_request_id = message_params[:client_request_id].to_s.strip
    @message.metadata = @message.metadata.merge("client_request_id" => client_request_id) if client_request_id.present?
    # Per-message tool selection from the composer's Tools dropdown: records
    # which subset of the agent's tools this message should run with. Absent
    # or empty means "agent config" — AgentRunner only ever narrows with it.
    selected_tools = Array(message_params[:tools]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    @message.metadata = @message.metadata.merge("tools" => selected_tools) if selected_tools.any?

    # Backend idempotency: a duplicate POST carrying the same correlation id
    # (double-click, an optimistic retry, a re-fired form) must never create a
    # second user message or enqueue a second run. The already-persisted row is
    # the authoritative one — acknowledge it without re-enqueuing so the
    # composer's success path resolves the guard cleanly.
    if client_request_id.present?
      existing = @conversation.messages.where(role: "user")
        .where("metadata->>'client_request_id' = ?", client_request_id)
        .order(:created_at).last
      if existing
        @message = existing
        respond_to do |format|
          format.turbo_stream { render "messages/create" }
          format.html { redirect_to conversation_path(@conversation) }
          format.json { render json: @message, status: :created }
        end
        return
      end
    end

    created = false
    failure_errors = nil
    ActiveRecord::Base.transaction do
      if @message.save
        @message.attach_assets!(message_params[:attachment_asset_ids], for_user: current_user)
        # Consume only the drafts whose asset actually attached, in the same
        # transaction — a rolled-back send leaves server drafts intact so the
        # composer can retry with its chips.
        AttachmentDraft.consume_attached_for(
          current_user, message_params[:attachment_draft_token], @message.assets.ids
        )
        created = true
      else
        failure_errors = @message.errors
      end
    rescue StandardError
      # Guardrail: raw errors never reach the client; the whole send rolls
      # back and the composer keeps text + chips for an honest retry.
      failure_errors = ActiveModel::Errors.new(@message).tap do |errors|
        errors.add(:base, "Could not send — the attachment part failed. Try again.")
      end
      raise ActiveRecord::Rollback
    end

    if created
      # Stream the agent response via Action Cable. The client_request_id is
      # passed through as request_id so every broadcast frame can be bridged to
      # the composer's optimistic assistant container (and de-duplicated).
      AgentStreamJob.perform_later(
        conversation_id: @conversation.id,
        user_id: current_user.id,
        message_content: @message.content,
        message_id: @message.id,
        request_id: client_request_id.presence
      )

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to conversation_path(@conversation) }
        format.json { render json: @message, status: :created }
      end
    else
      render json: { errors: failure_errors }, status: :unprocessable_entity
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  end

  def message_params
    params.require(:message).permit(
      :content, :attachment_draft_token, :client_request_id,
      attachment_asset_ids: [], tools: []
    )
  end
end
