# frozen_string_literal: true

module Assets
  module Extractors
    # Plain text / markdown / source-code extraction. Rejects binary content
    # (the validator already sniffs, but this is the second line of defense).
    class Text
      class << self
        def call(asset)
          bytes = asset.file.download
          raise ExtractionFailure.new(:unsupported_format) if bytes.include?("\x00")

          text = bytes.force_encoding("UTF-8").scrub
          truncated = text.length > BOUNDED_CONTENT_CHARS

          { content: text.first(BOUNDED_CONTENT_CHARS), meta: { bytes: bytes.bytesize, truncated: truncated, extractor: "text" } }
        end
      end
    end
  end
end
