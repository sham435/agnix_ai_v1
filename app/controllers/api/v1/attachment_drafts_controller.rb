# frozen_string_literal: true

module Api
  module V1
    # Attachment draft endpoints backing the composer's server-side draft
    # restore. Rows are strictly scoped to the current user AND the
    # client-held draft_token, so a token never surfaces another user's data.
    class AttachmentDraftsController < ApplicationController
      before_action :authenticate_user!

      def index
        token = params.require(:draft_token)
        AttachmentDraft.cleanup_expired_for(Current.user)

        drafts = AttachmentDraft.live_for(Current.user, token).map { |draft| draft_payload(draft) }
        render json: { drafts: drafts }
      end

      def create
        params.require(:draft_token)
        asset = Current.user.assets.find(params.require(:asset_id))
        raise ActiveRecord::RecordNotFound unless asset.readable_by?(Current.user)

        draft = AttachmentDraft.record!(
          user: Current.user,
          draft_token: params[:draft_token],
          asset: asset,
          label: params[:label]
        )

        render json: { draft: draft_payload(draft) }, status: (draft.previously_new_record? ? :created : :ok)
      rescue ActiveRecord::RecordInvalid
        render json: { error: "draft_rejected", error_code: "draft_invalid" }, status: :unprocessable_entity
      end

      def destroy
        draft = AttachmentDraft.live.where(user: Current.user, draft_token: params[:draft_token])
                               .find_by(id: params.require(:id))
        return head :no_content if draft.nil?

        draft.destroy!
        head :no_content
      end

      private

      def draft_payload(draft)
        asset = draft.asset
        {
          id: draft.id,
          asset_id: asset.id,
          label: draft.label.to_s.presence || asset.filename,
          filename: asset.filename,
          content_type: asset.content_type,
          byte_size: asset.byte_size,
          category: asset.metadata["category"],
          extraction_status: asset.extraction&.status,
          expires_at: draft.expires_at
        }
      end
    end
  end
end
