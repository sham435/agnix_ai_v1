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
        format.html { redirect_to images_path, notice: "Image queued for generation." }
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
        format.html { redirect_to images_path, alert: @image_generation.errors.full_messages.to_sentence }
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
    @new_generation = current_user.image_generations.new(
      @image_generation.attributes.slice("prompt", "model", "size", "quality", "n", "provider").merge(
        metadata: (@image_generation.metadata || {}).except("conversation_id", "revised_prompt",
                                                            "provider_id", "provider_created",
                                                            "provider_model", "image_count")
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
        format.html { redirect_to images_path, notice: "Regenerating this image." }
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
