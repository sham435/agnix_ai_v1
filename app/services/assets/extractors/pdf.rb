# frozen_string_literal: true

require "pdf/reader"
require "open3"
require "tmpdir"

module Assets
  module Extractors
    # PDF extraction through a real PDF parser (pdf-reader), preserving page
    # boundaries. Scanned / image-only documents fall back to genuine OCR:
    # Poppler renders pages to PNGs, Tesseract recognizes text. Nothing is
    # fabricated — an image-only PDF with no readable text fails honestly
    # with a safe code instead of pretending success.
    class Pdf
      MAX_PDF_PAGES = 20
      MAX_OCR_PAGES = 10
      MIN_EMBEDDED_TEXT_CHARS = 80
      RENDER_DPI = 150

      class << self
        def call(asset)
          bytes = asset.file.download
          raise ExtractionFailure.new(:unsupported_format) unless bytes.b.start_with?("%PDF")
          # Encrypted docs can't be parsed without the owner password — a
          # distinct, honest code from a structurally broken one.
          raise ExtractionFailure.new(:parse_error, "encrypted pdf") if bytes.include?("/Encrypt")

          Tempfile.create([ "shams-pdf", ".pdf" ]) do |file|
            file.binmode
            file.write(bytes)
            file.rewind

            extract_from_file(file.path)
          end
        end

        private

        def extract_from_file(path)
          reader = PDF::Reader.new(path)
          page_count = reader.page_count
          limit = [ page_count, MAX_PDF_PAGES ].min

          page_texts = (1..limit).map { |number| reader.page(number).text.to_s.strip }
          embedded_chars = page_texts.join.gsub(/\s+/, "").length
          embedded = page_texts.each_with_index
                               .map { |text, i| "## Page #{i + 1}\n#{text}" }
                               .join("\n\n")

          if embedded_chars >= MIN_EMBEDDED_TEXT_CHARS
            bounded_result(embedded, "pdf_text", page_count)
          else
            # Sparse / scanned document: real OCR on rendered pages, merged
            # with whatever embedded text exists (never discarded).
            begin
              ocr_text = ocr_fallback(path, [ page_count, MAX_OCR_PAGES ].min)
            rescue ExtractionFailure
              # No usable OCR (engine missing / nothing recognized): keep any
              # genuinely embedded text rather than fail — mark it honestly.
              raise if embedded_chars.zero?

              return { content: embedded.first(BOUNDED_CONTENT_CHARS),
                       meta: { extraction_method: "pdf_text", pages: page_count,
                               truncated: false, ocr_attempted: true } }
            end

            merged = [ ocr_text.presence, embedded.presence ].compact.join("\n\n")
            bounded_result(merged, "ocr", page_count)
          end
        rescue PDF::Reader::MalformedPDFError
          raise ExtractionFailure.new(:corrupt_document, "unreadable pdf structure")
        end

        # Renders bounded pages with Poppler and OCRs each with Tesseract.
        def ocr_fallback(path, page_count)
          # Check the renderer BEFORE spawning: a missing binary would raise
          # Errno::ENOENT out of capture3 instead of failing safely.
          raise ExtractionFailure.new(:ocr_unavailable) unless poppler_available?

          Dir.mktmpdir("shams-pdf-ocr-") do |dir|
            prefix = File.join(dir, "page")
            _out, _err, status = Open3.capture3("pdftoppm", "-f", "1", "-l", page_count.to_s,
                                                "-r", RENDER_DPI.to_s, "-png", path, prefix)
            raise ExtractionFailure.new(:parse_error, "pdf rendering failed") unless status.success?

            images = Dir.glob("#{prefix}-*.png").sort_by { |f| f[/-(\d+)\.png$/, 1].to_i }
            raise ExtractionFailure.new(:parse_error, "pdf rendering produced no pages") if images.empty?

            text = images.filter_map { |image| Assets::Ocr.call(image) rescue nil }.join("\n\n")
            raise ExtractionFailure.new(:no_text_found) if text.blank?

            text
          end
        end

        def poppler_available?
          Open3.capture3("which", "pdftoppm")[0].strip.present?
        rescue StandardError
          false
        end

        def bounded_result(text, method, page_count)
          text = text.to_s.strip
          raise ExtractionFailure.new(:no_text_found) if text.blank?

          truncated = text.length > BOUNDED_CONTENT_CHARS
          text = text.first(BOUNDED_CONTENT_CHARS)
          {
            content: text,
            meta: {
              extraction_method: method,
              pages: page_count,
              pages_processed: method == "ocr" ? [ page_count, MAX_OCR_PAGES ].min : nil,
              truncated: truncated
            }.compact
          }
        end
      end
    end
  end
end
