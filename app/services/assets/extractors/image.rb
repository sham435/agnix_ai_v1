# frozen_string_literal: true

module Assets
  module Extractors
    # Image extraction through real OCR (Tesseract). Extracts only what the
    # engine genuinely recognizes; photos without readable text fail with
    # no_text_found, and a missing engine fails with ocr_unavailable.
    class Image
      class << self
        def call(asset)
          bytes = asset.file.download
          Tempfile.create([ "shams-image", File.extname(asset.filename.to_s) ]) do |file|
            file.binmode
            file.write(bytes)
            file.rewind

            text = Assets::Ocr.call(file.path)
            bounded_path(text)
          end
        end

        private

        def bounded_path(text)
          truncated = text.length > BOUNDED_CONTENT_CHARS
          text = text.first(BOUNDED_CONTENT_CHARS)
          { content: text, meta: { extraction_method: "ocr", truncated: truncated } }
        end
      end
    end
  end
end
