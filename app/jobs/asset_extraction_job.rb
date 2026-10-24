# frozen_string_literal: true

# Async asset extraction with explicit processing states and safe error
# codes: pending -> processing -> completed | failed. Raw errors and file
# bytes never reach the client; failures collapse into the bounded error
# vocabulary on AssetExtraction.
#
# Retry policy: only transient infrastructure faults (deadlocks / connection
# timeouts) are retried with backoff. Extraction itself is deterministic —
# a corrupt document or unreadable scan would fail again identically, so
# those are recorded immediately with their safe code.
class AssetExtractionJob < ApplicationJob
  queue_as :default

  TRANSIENT_ERRORS = [ ActiveRecord::Deadlocked, ActiveRecord::ConnectionTimeoutError ].freeze

  # On retry exhaustion mark the extraction failed instead of re-raising —
  # the bounded state machine owns the failure surface, not the queue.
  retry_on(*TRANSIENT_ERRORS, wait: :exponentially_longer, attempts: 3) do |job, _error|
    AssetExtraction.find_by(id: job.arguments.first)&.update!(
      status: "failed", error_code: "extraction_error", content: nil
    )
  end

  def perform(extraction_id)
    extraction = AssetExtraction.find_by(id: extraction_id)
    return if extraction.nil? || extraction.completed? || extraction.canceled?

    extraction.update!(status: "processing")

    result = Assets::Extractors.run_for(extraction.asset)
    extraction.update!(status: "completed", content: result[:content], meta: result[:meta], error_code: nil)
  rescue Assets::Extractors::ExtractionFailure => e
    record_failure(extraction, e.safe_code)
  rescue StandardError => e
    # Transient infrastructure faults flow up so retry_on schedules them;
    # everything else is a deterministic failure recorded with a safe code.
    raise if TRANSIENT_ERRORS.any? { |klass| e.is_a?(klass) }

    Rails.logger.error("[AssetExtractionJob] failed extraction_id=#{extraction_id} #{e.class}: #{e.message}")
    record_failure(extraction, :extraction_error)
  end

  private

  def record_failure(extraction, code)
    return if extraction.nil?

    extraction.update!(status: "failed", error_code: code.to_s, content: nil)
  end
end
