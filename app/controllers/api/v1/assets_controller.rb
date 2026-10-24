# frozen_string_literal: true

module Api
  module V1
    # Canonical asset endpoints: upload (strict validation + dedupe),
    # library listing (pointing at assets — selecting a Library file never
    # re-uploads bytes), authorized download, add-to-library, destroy.
    class AssetsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_asset, only: %i[show destroy download add_to_library preview]

      def create
        result = Assets::Ingest.call(
          user: Current.user,
          upload: params[:file],
          project: project_for_ingest
        )

        render json: asset_payload(result.asset, result.extraction&.reload),
               status: (result.created? ? :created : :ok)
      rescue Assets::Ingest::InvalidUpload => e
        render json: { error: "upload_rejected", error_code: e.error_code }, status: :unprocessable_entity
      end

      def show
        render json: asset_payload(@asset, @asset.extraction)
      end

      def destroy
        @asset.file.purge
        @asset.destroy!
        head :no_content
      end

      def download
        blob = @asset.file.blob
        return head :not_found unless blob

        data = @asset.file.download
        disposition = @asset.image? ? "inline" : "attachment"

        send_data data,
                  type: @asset.content_type,
                  filename: @asset.filename,
                  disposition: disposition
      end

      def add_to_library
        item = LibraryItem.find_or_create_by!(user: @asset.user, asset: @asset)
        head (item.previously_new_record? ? :created : :ok)
      end

      # Library listing with optional search + category filter. `q` matches the
      # item label, the asset filename, or its content type (case-insensitive);
      # `category` narrows to one asset category. Newest first, capped so a huge
      # library never over-fetches.
      def library
        items = Current.user.library_items.includes(:asset, asset: :extraction)
        items = apply_library_filters(items)
        items = items.order(created_at: :desc).limit(library_limit)
        render json: { items: items.map { |item| library_payload(item) } }
      end

      # Lightweight preview for the Library panel: extracted text (head-truncated)
      # plus structural metadata, or an image flag so the UI can render the
      # authorized download URL as a thumbnail. Never returns the whole document.
      PREVIEW_CHARS = 2_000

      def preview
        extraction = @asset.extraction
        render json: preview_payload(@asset, extraction)
      end

      private

      def apply_library_filters(items)
        q = params[:q].to_s.strip
        if q.present?
          like = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
          items = items
            .left_outer_joins(:asset)
            .where(
              "LOWER(COALESCE(library_items.label, '')) LIKE LOWER(:q) " \
              "OR LOWER(assets.filename) LIKE LOWER(:q) " \
              "OR LOWER(assets.content_type) LIKE LOWER(:q)",
              q: like
            )
        end

        category = params[:category].to_s.strip
        items = items.joins(:asset).where("assets.metadata->>'category' = ?", category) if category.present? && category != "all"

        items
      end

      def library_limit
        requested = params[:limit].to_i
        requested = 100 if requested <= 0
        [ requested, 250 ].min
      end

      def preview_payload(asset, extraction)
        content = extraction&.content.to_s
        {
          asset: {
            id: asset.id,
            filename: asset.filename,
            content_type: asset.content_type,
            byte_size: asset.byte_size,
            category: asset.metadata["category"],
            image: asset.image?,
            download_url: asset.image? ? download_api_v1_asset_path(asset) : nil
          },
          extraction: {
            status: extraction&.status,
            error_code: extraction&.error_code,
            truncated: content.length > PREVIEW_CHARS || extraction&.meta&.[]("truncated").present?,
            preview: content[0, PREVIEW_CHARS],
            pages: extraction&.meta&.[]("pages"),
            sheets: extraction&.meta&.[]("sheets"),
            bytes: extraction&.meta&.[]("bytes")
          }
        }
      end

      def set_asset
        @asset = Current.user.assets.find(params[:id])
        # Cross-user assets are never visible via this controller: scoped above.
        raise ActiveRecord::RecordNotFound unless @asset.readable_by?(Current.user)
      end

      def project_for_ingest
        return nil if params[:project_id].blank?

        project = Project.find(params[:project_id])
        raise ActiveRecord::RecordNotFound unless project.user_id == Current.user.id

        project
      end

      def asset_payload(asset, extraction = nil)
        {
          asset: {
            id: asset.id,
            filename: asset.filename,
            content_type: asset.content_type,
            byte_size: asset.byte_size,
            category: asset.metadata["category"],
            status: asset.status,
            created_at: asset.created_at
          },
          extraction: extraction ? {
            status: extraction.status,
            error_code: extraction.error_code,
            truncated: extraction.meta["truncated"].present?,
            sheets: extraction.meta["sheets"],
            pages: extraction.meta["pages"],
            bytes: extraction.meta["bytes"]
          } : nil
        }
      end

      def library_payload(item)
        asset = item.asset
        {
          id: item.id,
          label: item.label || asset.filename,
          asset_id: asset.id,
          filename: asset.filename,
          content_type: asset.content_type,
          byte_size: asset.byte_size,
          category: asset.metadata["category"],
          extraction_status: asset.extraction&.status
        }
      end
    end
  end
end
