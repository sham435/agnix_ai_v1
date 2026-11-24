# frozen_string_literal: true

require "base64"
require "tempfile"
require "mini_magick"

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
  # successfully claimed from queued reach the provider; fresh duplicates are
  # inert and stale redeliveries only close the abandoned row.
  class GenerateJob < ApplicationJob
    queue_as :images

    Upload = Struct.new(:tempfile, :original_filename)

    def perform(image_generation_id)
      generation = ImageGeneration.find_by(id: image_generation_id)
      return if generation.nil?

      # A crashed worker cannot finish its row. Close a stale lease honestly,
      # but never call the non-idempotent provider endpoint again from here.
      if generation.recover_stale_running!
        broadcast_gallery(generation)
        broadcast_to_conversation(generation)
        return
      end

      return unless generation.claim!

      begin
        broadcast_gallery(generation)
        result = Generator.new(model: generation.model).generate(
          prompt: generation.prompt,
          size: generation.size,
          quality: generation.quality,
          n: generation.n
        )
        finish!(generation, result)
      rescue Generator::RateLimited => e
        fail!(generation, e.message, metadata: {
          "retry_after" => e.retry_after, "retry_at" => e.retry_at&.utc&.iso8601
        })
      rescue Assets::Ingest::InvalidUpload
        fail!(generation, "The generated image could not be stored.")
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
        metadata: generation.normalized_metadata.merge(
          "revised_prompt" => image.revised_prompt,
          "provider_id" => image.provider_id,
          "provider_created" => result.created,
          "provider_model" => result.model,
          "image_count" => result.images.size
        ).compact
      )

      broadcast_gallery(generation)
      broadcast_to_conversation(generation)
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

      validate_image!(tempfile.path)
      filename = "generated-#{generation.id.to_s[0, 8]}.png"
      result = Assets::Ingest.call(
        user: generation.user,
        upload: Upload.new(tempfile, filename),
        project: nil
      )
      asset = result.asset
      unless asset&.persisted? && asset.status == "ready" && asset.image? && asset.file.attached?
        raise Generator::Error, "The generated image could not be stored."
      end
      asset.file.open { |file| validate_image!(file.path) }
      asset
    ensure
      tempfile&.close
      tempfile&.unlink
    end

    def decode(b64_json)
      raise Generator::Error, "The image provider returned unreadable image data." if b64_json.blank?

      Base64.strict_decode64(b64_json).tap do |bytes|
        raise Generator::Error, "The image provider returned an empty image." if bytes.empty?
      end
    rescue ArgumentError
      raise Generator::Error, "The image provider returned unreadable image data."
    end

    def validate_image!(path)
      image = MiniMagick::Image.new(path)
      image.validate!
      unless image.type == "PNG" && image.width.positive? && image.height.positive?
        raise Generator::Error, "The image provider returned invalid image data."
      end
    rescue MiniMagick::Error
      raise Generator::Error, "The image provider returned invalid image data."
    end

    def fail!(generation, message, metadata: {})
      return if generation.succeeded?

      generation.mark_failed!(message, metadata: metadata)
      broadcast_gallery(generation)
      broadcast_to_conversation(generation)
    end

    def broadcast_gallery(generation)
      html = ApplicationController.render(partial: "images/card", locals: { generation: generation })
      Turbo::StreamsChannel.broadcast_replace_to(
        ImageGeneration.gallery_stream_name(generation.user),
        target: "image-generation-#{generation.id}", html: html
      )
    end

    def broadcast_to_conversation(generation)
      conversation_id = generation.normalized_metadata["conversation_id"]
      return if conversation_id.blank?

      # Metadata can be forged or inherited from legacy rows. Ownership is
      # determined only through the generation owner's conversation scope.
      conversation = generation.user.conversations.find_by(id: conversation_id)
      return if conversation.nil?

      html = ApplicationController.render(partial: "images/chat_card", locals: { generation: generation })
      Turbo::StreamsChannel.broadcast_append_to(conversation, target: "messages-list", html: html)
    end
  end
end
