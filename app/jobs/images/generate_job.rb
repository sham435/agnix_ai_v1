# frozen_string_literal: true

require "base64"
require "tempfile"

module Images
  # Solid Queue worker behind every ImageGeneration row (gallery create,
  # regenerate, in-chat tool). Owns the whole lifecycle: running -> provider
  # call -> base64 bytes through the existing Assets ingest pipeline ->
  # succeeded/failed, with Turbo Stream broadcasts to the /images gallery and
  # — for chat-originated generations — an image card into the conversation.
  #
  # Failure policy: provider/user-facing errors are recorded on the row (never
  # re-raised), because a retry would silently spend money again — the gallery
  # and chat cards expose an explicit Regenerate action instead. Only rows that
  # are still queued/running are processed, so double enqueues are inert.
  class GenerateJob < ApplicationJob
    queue_as :images

    # Shared gallery stream (same convention as the "scheduled_tasks" stream).
    GALLERY_STREAM = "image_generations"

    Upload = Struct.new(:tempfile, :original_filename)

    def perform(image_generation_id)
      generation = ImageGeneration.find_by(id: image_generation_id)
      return if generation.nil?
      return unless generation.queued? || generation.running?

      generation.update!(status: "running")
      broadcast_gallery(generation)

      begin
        result = Generator.new(model: generation.model).generate(
          prompt: generation.prompt,
          size: generation.size,
          quality: generation.quality,
          n: generation.n
        )
        finish!(generation, result)
      rescue Generator::Error => e
        fail!(generation, e.message)
      rescue StandardError => e
        Rails.logger.error("[Images::GenerateJob] generation=#{image_generation_id} #{e.class}: #{e.message}")
        fail!(generation, "Image generation failed unexpectedly. Please try again.")
      end
    end

    private

    def finish!(generation, result)
      image = result.images.first
      raise Generator::Error, "The image provider returned no images." if image.nil?

      asset = store_asset(generation, image)
      generation.update!(
        status: "succeeded",
        asset: asset,
        metadata: (generation.metadata || {}).merge(
          "revised_prompt" => image.revised_prompt,
          "provider_id" => image.provider_id,
          "provider_created" => result.created,
          "provider_model" => result.model,
          "image_count" => result.images.size
        ).compact
      )

      broadcast_gallery(generation)
      broadcast_to_conversation(generation) if generation.metadata["conversation_id"].present?
    end

    # Decode -> Tempfile(.png) -> Assets::Ingest: validation, SHA256 dedupe,
    # Active Storage attachment, library entry and extraction kickoff all come
    # from the canonical upload pipeline rather than a bespoke copy.
    def store_asset(generation, image)
      bytes = decode(image.b64_json)
      tempfile = Tempfile.new([ "generated-#{generation.id.to_s[0, 8]}", ".png" ])
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.flush
      tempfile.rewind

      filename = "generated-#{generation.id.to_s[0, 8]}.png"
      result = Assets::Ingest.call(
        user: generation.user,
        upload: Upload.new(tempfile, filename),
        project: nil
      )
      result.asset
    ensure
      tempfile&.close
      tempfile&.unlink
    end

    def decode(b64_json)
      raise Generator::Error, "The image provider returned unreadable image data." if b64_json.blank?

      Base64.decode64(b64_json).tap do |bytes|
        raise Generator::Error, "The image provider returned an empty image." if bytes.empty?
      end
    end

    def fail!(generation, message)
      generation.mark_failed!(message)
      broadcast_gallery(generation)
      broadcast_to_conversation(generation) if generation.metadata["conversation_id"].present?
    end

    def broadcast_gallery(generation)
      html = ApplicationController.render(partial: "images/card", locals: { generation: generation })
      Turbo::StreamsChannel.broadcast_replace_to(
        GALLERY_STREAM, target: "image-generation-#{generation.id}", html: html
      )
    end

    def broadcast_to_conversation(generation)
      conversation = Conversation.find_by(id: generation.metadata["conversation_id"])
      return if conversation.nil?

      html = ApplicationController.render(partial: "images/chat_card", locals: { generation: generation })
      Turbo::StreamsChannel.broadcast_append_to(conversation, target: "messages-list", html: html)
    end
  end
end
