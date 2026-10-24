# frozen_string_literal: true

require "open3"

module Assets
  # Real OCR through the Tesseract engine. System tool expected on PATH
  # (brew install tesseract). Never fabricates text: an empty recognition
  # result is reported as no_text_found, a missing binary as ocr_unavailable.
  #
  # Wall-clock timeout is REAL: after TIMEOUT_SECONDS the reader streams are
  # closed (which unblocks the read) and the process is killed — capture3
  # alone would wait forever on a stuck process.
  class Ocr
    TIMEOUT_SECONDS = 60
    DEFAULT_LANGUAGES = "eng"

    class << self
      def available?
        binary_path.present?
      end

      def binary_path
        candidates = [ ENV["SHAMS_TESSERACT_BIN"], "tesseract" ].compact
        candidates.find do |candidate|
          out = Open3.capture3("which", candidate)[0]
          out.strip.present?
        rescue StandardError
          next
        end
      end

      def call(image_path, languages: nil)
        binary = binary_path
        raise Extractors::ExtractionFailure.new(:ocr_unavailable) if binary.blank?

        languages = languages.presence || ENV["OCR_LANGUAGES"].presence || DEFAULT_LANGUAGES
        out, _err, wait_thr, timed_out = run_tesseract(binary, image_path, languages)

        raise Extractors::ExtractionFailure.new(:extraction_tool_failed, "ocr timeout") if timed_out

        text = out.to_s.strip
        raise Extractors::ExtractionFailure.new(:no_text_found) if text.blank?

        text
      end

      private

      # Returns [stdout, stderr, wait_thr, timed_out]. The read blocks until
      # the process closes stdout — or until the timeout thread closes the
      # streams and kills the process, in which case timed_out is true.
      def run_tesseract(binary, image_path, languages)
        # popen3 returns [stdin, stdout, stderr, wait_thr] — stdin is not used.
        _, out, err, wait_thr = Open3.popen3(binary, image_path, "-", "-l", languages, "--psm", "3", "quiet")

        timed_out = false
        timeout_thread = Thread.new do
          sleep TIMEOUT_SECONDS
          timed_out = true
          [ out, err ].each { |stream| stream.close rescue nil }
          wait_thr.kill
        end

        stdout = out.read
        [ stdout, err.read, wait_thr, timed_out ].tap { timeout_thread.kill }
      end
    end
  end
end
