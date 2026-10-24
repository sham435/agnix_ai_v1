# frozen_string_literal: true

# Per-asset extraction record (text pulled out of files for use in chat).
# One row per asset (unique). Content is bounded by the extractor, never
# storing arbitrary unbounded output, and `error_code` comes from a fixed
# safe vocabulary — raw exceptions/messages never reach the client.
class AssetExtraction < ApplicationRecord
  STATUS_VALUES = %w[
    pending
    processing
    completed
    failed
    canceled
  ].freeze

  # String-backed enum: bounded status values + generated predicates
  # (completed?, canceled?) used by the extraction job.
  enum :status, STATUS_VALUES.index_by(&:to_s), validate: true

  # Safe, client-facing error vocabulary. Everything else collapses to
  # `extraction_error` and the raw message stays in the server log only.
  ERROR_CODES = %w[
    extraction_error
    unsupported_format
    malformed_archive
    corrupt_document
    parse_error
    ocr_unavailable
    content_too_large
    no_text_found
    extraction_tool_failed
  ].freeze

  belongs_to :asset

  validates :status, inclusion: { in: STATUS_VALUES }
  validates :error_code, inclusion: { in: ERROR_CODES, allow_nil: true }
  # Bounded extraction content (approx 200k chars max per asset).
  validates :content, length: { maximum: 200_000 }, allow_nil: true

  validate :meta_shape

  def meta_shape
    errors.add(:meta, "must be a hash") unless meta.is_a?(Hash)
  end

  scope :pending_or_processing, -> { where(status: %w[pending processing]) }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
end
