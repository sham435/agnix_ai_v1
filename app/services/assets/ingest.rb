# frozen_string_literal: true

require "digest"

module Assets
  # Canonical ingest path: validate -> checksum dedupe (duplicate ingests for
  # the same user resolve to the existing asset, never storing bytes twice)
  # -> atomically create, upload/attach, register extraction + Library, enqueue.
  class Ingest
    class InvalidUpload < StandardError
      attr_reader :error_code

      def initialize(error_code)
        super(error_code.to_s)
        @error_code = error_code
      end
    end

    Result = Data.define(:asset, :created, :extraction) do
      def created?
        created
      end

      # true when the upload resolved to an existing asset (dedupe/Library reuse)
      def reused?
        !created
      end
    end

    class << self
      def call(user:, upload:, project: nil, label: nil)
        if project.present? && project.user_id != user.id
          raise ActiveRecord::RecordNotFound, "project not owned by ingest user"
        end

        tempfile = upload.respond_to?(:tempfile) ? upload.tempfile : upload
        result = Validator.validate(tempfile, filename: upload.respond_to?(:original_filename) ? upload.original_filename : nil)

        raise InvalidUpload, result.error_code unless result.ok?

        checksum = Digest::SHA256.file(tempfile.path).hexdigest
        tempfile.rewind if tempfile.respond_to?(:rewind)

        if (existing = Asset.find_by(user: user, checksum: checksum))
          # A ready checksum row without bytes is incomplete, not a reusable
          # asset. Reject it rather than passing a broken dedupe hit downstream.
          raise InvalidUpload, :attachment_missing unless existing.file.attached?

          # Re-ingest (dedupe / Library reuse) still guarantees the file is in
          # the user's Library so the panel reflects everything they've uploaded.
          ensure_library_item(user, existing, label: label)
          return Result.new(asset: existing, created: false, extraction: existing.extraction)
        end

        asset = nil
        extraction = nil
        Asset.transaction do
          asset = Asset.create!(
            user: user,
            project: project,
            filename: File.basename(upload.original_filename.to_s.b),
            content_type: result.content_type,
            byte_size: tempfile.size,
            checksum: checksum,
            status: "ready",
            metadata: {
              "category" => result.category,
              "ext" => File.extname(upload.original_filename.to_s).delete_prefix(".").downcase
            }
          )

          # Upload before commit so a storage failure raises inside this
          # transaction. Attaching an IO directly defers the physical upload to
          # after_commit, which is too late to roll back a ready checksum row.
          tempfile.rewind if tempfile.respond_to?(:rewind)
          blob = ActiveStorage::Blob.create_and_upload!(
            io: tempfile, filename: asset.filename, content_type: result.content_type,
            identify: false, record: asset
          )
          asset.file.attach(blob)
          unless asset.file.attachment&.persisted?
            raise ActiveRecord::RecordNotSaved, "Asset attachment could not be persisted"
          end

          extraction = AssetExtraction.create!(asset: asset, status: "pending", meta: {})
          # Auto-library: an upload is instantly reusable across conversations
          # without a second upload or a manual "add to library" step.
          ensure_library_item(user, asset, label: label)

          # Active Job reports adapter enqueue failures as false. Treat that as
          # a transaction failure instead of leaving an unprocessable ready row.
          enqueued = AssetExtractionJob.perform_later(extraction.id)
          raise ActiveJob::EnqueueError, "Asset extraction could not be enqueued" unless enqueued
        end

        Result.new(asset: asset, created: true, extraction: extraction)
      end

      private

      # Idempotent: a user never gets a duplicate Library row for the same
      # asset (unique index on [user_id, asset_id]). Optional label renames the
      # entry the first time it is supplied.
      def ensure_library_item(user, asset, label: nil)
        item = LibraryItem.find_or_create_by!(user: user, asset: asset)
        if label.present? && item.label.blank?
          item.update!(label: label.to_s.strip[0, 255])
        end
        item
      rescue ActiveRecord::RecordNotUnique
        LibraryItem.find_by(user: user, asset: asset)
      end
    end
  end
end
