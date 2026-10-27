class Api::V1::MessagesController < ApplicationController
  before_action :authenticate_user!

  def create
    @conversation = current_user.conversations.find(params[:conversation_id])

    message = @conversation.messages.build(
      role: "user",
      content: params[:content]
    )
    message.pending_attachment_asset_ids = params[:attachment_asset_ids]

    created = false
    ActiveRecord::Base.transaction do
      message.save!
      message.attach_assets!(params[:attachment_asset_ids], for_user: current_user)
      # Same consumer semantics as the web composer: only drafts whose asset
      # truly attached disappear (inside the commit boundary).
      AttachmentDraft.consume_attached_for(current_user, params[:attachment_draft_token], message.assets.ids)
      created = true
    rescue StandardError
      raise ActiveRecord::Rollback
    end
    raise(ActiveRecord::RecordInvalid, message) unless created

    # Queue agent response.
    AgentStreamJob.perform_later(
      conversation_id: @conversation.id,
      user_id: current_user.id,
      message_content: message.content
    )

    render json: { message: message, status: :processing }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors }, status: :unprocessable_entity
  end
end
