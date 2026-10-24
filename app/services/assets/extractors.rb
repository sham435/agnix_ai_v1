# frozen_string_literal: true

module Assets
  # Raised by extractors with a safe, client-facing error code. Raw error
  # messages and backtraces stay server-side.
  module Extractors
    class ExtractionFailure < StandardError
      attr_reader :safe_code

      def initialize(safe_code, message = nil)
        super(message || safe_code)
        @safe_code = safe_code
      end
    end
  end

  # Dispatches extraction for an asset to the right extractor based on its
  # stored category. Extractors return { content:, meta: } and may raise
  # ExtractionFailure with a safe error code.
  module Extractors
    BOUNDED_CONTENT_CHARS = 200_000

    class << self
      def run_for(asset)
        case asset.metadata["category"]
        when "image"
          Image.call(asset)
        when "data"
          Csv.call(asset)
        when "spreadsheet"
          Xlsx.call(asset)
        when "document"
          asset.filename.to_s.downcase.end_with?(".pdf") ? Pdf.call(asset) : Docx.call(asset)
        when "text"
          Text.call(asset)
        else
          raise ExtractionFailure.new(:unsupported_format)
        end
      end
    end
  end
end
