# frozen_string_literal: true

# Phase 3 — Image Generation gallery (/images). Everything is hard-scoped to
# the signed-in user: the grid, the optimistic turbo-stream cards, downloads.
# Controllers only orchestrate (scope, queue, respond); generation mechanics
# live in Images::Generator / Images::GenerateJob.
class ImagesController < ApplicationController
  include Pagy::Backend

  GALLERY_PAGE_SIZE = 24

  before_action :authenticate_user!
  before_action :set_image_generation, only: [ :show, :destroy, :regenerate ]

  rescue_from ActiveRecord::RecordNotFound, with: :redirect_missing

  def index
    @origin_conversation = origin_conversation
    @back_to_chat = @origin_conversation || current_user.conversations.where(status: "active").order(updated_at: :desc).first
    @back_to_chat_path = @back_to_chat ? origin_chat_path(@back_to_chat) : conversations_path
    @pagy, @image_generations = pagy(
      current_user.image_generations.order(created_at: :desc),
      limit: GALLERY_PAGE_SIZE,
      page: params[:page]
    )
  end

  # Renders inside the top-level "modal" turbo frame (click-to-enlarge).
  def show
  end

  def create
    @image_generation = current_user.image_generations.new(image_generation_params)
    @image_generation.organization_id = current_organization&.id
    if (conversation = origin_conversation)
      @image_generation.organization_id = conversation.agent.organization_id
      @image_generation.metadata = { "conversation_id" => conversation.id, "conversation_path" => origin_chat_path(conversation) }
    end

    if @image_generation.save
      Images::GenerateJob.perform_later(@image_generation.id)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.prepend("images-grid", partial: "images/card",
                                 locals: { generation: @image_generation }),
            turbo_stream.remove("images-empty"),
            turbo_stream.update("image-form-error", html: ""),
            turbo_stream.update("image_generation_prompt", html: "")
          ]
        end
        format.json { render json: generation_payload(@image_generation), status: :accepted }
        format.html do
          redirect_to images_path_with_context(@image_generation), notice: "Image queued for generation."
        end
      end
    else
      respond_to do |format|
        format.turbo_stream do
          message = ERB::Util.html_escape(@image_generation.errors.full_messages.to_sentence)
          render status: :unprocessable_entity, turbo_stream:
            turbo_stream.update("image-form-error",
                                html: %(<p class="text-[13px] text-red-600 dark:text-red-400">#{message}</p>).html_safe)
        end
        format.json { render json: { errors: @image_generation.errors.full_messages }, status: :unprocessable_entity }
        format.html do
          redirect_to images_path_with_context(@image_generation),
                      alert: @image_generation.errors.full_messages.to_sentence
        end
      end
    end
  end

  def destroy
    @image_generation.destroy!
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove("image-generation-#{@image_generation.id}") }
      format.json { head :no_content }
      format.html { redirect_to images_path, notice: "Image removed from the gallery." }
    end
  end

  # Re-runs the same prompt as a NEW gallery entry (history is preserved —
  # failed rows stay visible with their error until deleted).
  def regenerate
    unless @image_generation.retry_available?
      message = @image_generation.error.presence || "This image is still generating. Wait before retrying."
      return redirect_to images_path_with_context(@image_generation), alert: message, status: :see_other
    end

    @new_generation = current_user.image_generations.new(
      @image_generation.attributes.slice("prompt", "model", "size", "quality", "n", "provider").merge(
        metadata: @image_generation.normalized_metadata.except(
          "revised_prompt", "provider_id", "provider_created", "provider_model", "image_count",
          "retry_after", "retry_at"
        )
      )
    )

    if @new_generation.save
      Images::GenerateJob.perform_later(@new_generation.id)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.prepend("images-grid", partial: "images/card",
                                 locals: { generation: @new_generation }),
            turbo_stream.replace("image-generation-#{@image_generation.id}",
                                 partial: "images/card", locals: { generation: @image_generation })
          ]
        end
        format.html do
          redirect_to images_path_with_context(@new_generation), notice: "Regenerating this image."
        end
      end
    else
      redirect_to images_path, alert: "Could not regenerate this image."
    end
  end

  # Active Storage bytes are on the private Disk service; downloads are proxied
  # through this action so Asset#readable_by? is the single authorization gate.
  # Cross-user access answers 404 directly (no redirect) — the resource must
  # not even appear to exist for someone else.
  def download
    generation = ImageGeneration.find_by(id: params[:id])
    asset = generation&.asset
    if generation.nil? || asset.nil? || !asset.readable_by?(current_user)
      return head :not_found
    end

    return head :not_found unless asset.file.attached?

    disposition = asset.image? ? "inline" : "attachment"
    send_data asset.file.download,
              type: asset.content_type,
              filename: asset.filename,
              disposition: disposition
  end

  private

  def set_image_generation
    @image_generation = current_user.image_generations.find(params[:id])
  end

  def redirect_missing
    respond_to do |format|
      format.html { redirect_to images_path, alert: "Image not found." }
      format.any { head :not_found }
    end
  end

  def images_path_with_context(generation)
    metadata = generation.normalized_metadata
    images_path(conversation_id: metadata["conversation_id"], return_to: metadata["conversation_path"])
  end

  def origin_conversation
    id = params[:conversation_id].presence || params.dig(:image_generation, :conversation_id).presence
    current_user.conversations.find_by(id: id) if id
  end

  def origin_chat_path(conversation)
    fallback = conversation_path(conversation)
    return fallback if params[:return_to].blank?

    uri = URI.parse(params[:return_to])
    uri.scheme.nil? && uri.host.nil? && uri.path == fallback ? uri.to_s : fallback
  rescue URI::InvalidURIError
    fallback
  end

  def image_generation_params
    params.require(:image_generation).permit(:prompt, :model, :size, :quality)
  end

  def generation_payload(generation)
    {
      id: generation.id,
      prompt: generation.prompt,
      status: generation.status,
      model: generation.model,
      size: generation.size,
      quality: generation.quality,
      asset_id: generation.asset_id,
      created_at: generation.created_at.iso8601
    }
  end
end
