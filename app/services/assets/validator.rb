# frozen_string_literal: true

require "digest"

module Assets
  # Strict upload validation: extension allowlist, canonical MIME mapping
  # (the client's declared MIME is never trusted), magic-byte sniffing for
  # binary formats, size limits, and an executable blocklist.
  class Validator
    Result = Data.define(:category, :content_type, :error_code) do
      def ok?
        error_code.nil?
      end
    end

    MAX_SIZE = 25.megabytes
    MAX_IMAGE_SIZE = 10.megabytes

    FORBIDDEN_EXTENSIONS = %w[
      exe dll so dylib bat cmd msi bin com jar class app dmg pkg deb rpm iso
    ].freeze

    OFFICE_ZIP_PREFIX = "PK\x03\x04".freeze

    IMAGE_SIGNATURES = {
      "png" => "\x89PNG\r\n\x1a\n",
      "jpg" => "\xFF\xD8\xFF",
      "gif" => "GIF8",
      "webp" => "RIFF"
    }.freeze

    CODE_EXTENSIONS = %w[
      rb py js mjs cjs ts tsx jsx json html htm css scss java go rs c h cpp hpp
      php sql xml toml yml yaml ini cfg conf log swift kt cs
    ].freeze

    TEXT_EXTENSIONS = (%w[txt md markdown] + CODE_EXTENSIONS).freeze

    BASE_SPECS = {
      "png"   => { category: "image",      mime: "image/png" },
      "jpg"   => { category: "image",      mime: "image/jpeg" },
      "jpeg"  => { category: "image",      mime: "image/jpeg" },
      "gif"   => { category: "image",      mime: "image/gif" },
      "webp"  => { category: "image",      mime: "image/webp" },
      "pdf"   => { category: "document",   mime: "application/pdf" },
      "docx"  => { category: "document",   mime: "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
      "xlsx"  => { category: "spreadsheet", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
      "csv"   => { category: "data",       mime: "text/csv" }
    }.freeze

    TEXT_SPECS = TEXT_EXTENSIONS
      .map { |ext| [ ext, { category: "text", mime: "text/plain" } ] }
      .to_h.freeze

    ALLOWED = BASE_SPECS.merge(TEXT_SPECS).freeze

    class << self
      def validate(upload, filename:, declared_mime: nil)
        return fail(:file_missing) if upload.blank?

        filename_str = filename.to_s
        return fail(:file_missing) if filename_str.blank?

        size = upload.respond_to?(:size) ? upload.size.to_i : 0
        return fail(:empty_file) if size.zero?
        if size > max_size_for(filename_str)
          return fail(:too_large)
        end

        ext = extension(filename_str)
        return fail(:executable_forbidden) if forbidden_extension?(filename_str)
        return fail(:executable_forbidden) if FORBIDDEN_EXTENSIONS.include?(ext)

        spec = ALLOWED[ext]
        return fail(:unsupported_type) if spec.nil?

        return fail(:mime_mismatch) unless magic_matches?(spec[:category], ext, upload)

        Result.new(category: spec[:category], content_type: spec[:mime], error_code: nil)
      end

      private

      def extension(filename)
        File.extname(File.basename(filename.to_s)).delete_prefix(".").downcase
      end

      def forbidden_extension?(filename)
        base = File.basename(filename.to_s)
        exts = base.scan(/\.([A-Za-z0-9]+)/).flatten
        exts.any? { |e| FORBIDDEN_EXTENSIONS.include?(e.downcase) }
      end

      def max_size_for(filename)
        ext = File.extname(filename).delete_prefix(".").downcase
        %w[png jpg jpeg gif webp].include?(ext) ? MAX_IMAGE_SIZE : MAX_SIZE
      end

      def magic_matches?(category, ext, upload)
        header = (leading_bytes(upload, 12) || "").b
        case category
        when "image"
          sig = IMAGE_SIGNATURES[ext]
          header.start_with?(sig.b)
        when "document"
          ext == "pdf" ? header.start_with?("%PDF-") : header.start_with?(OFFICE_ZIP_PREFIX)
        when "spreadsheet"
          header.start_with?(OFFICE_ZIP_PREFIX)
        when "data", "text"
          text_like?(upload)
        else
          true
        end
      end

      def leading_bytes(upload, count)
        upload.rewind if upload.respond_to?(:rewind)
        upload.read(count)
      ensure
        upload.rewind if upload.respond_to?(:rewind)
      end

      def text_like?(upload)
        sample = leading_bytes(upload, 8192)
        return false if sample.nil?
        return false if sample.include?("\u0000")

        sample.force_encoding("UTF-8").valid_encoding? ||
          sample.force_encoding("ISO-8859-1").valid_encoding?
      end

      def fail(code)
        Result.new(category: nil, content_type: nil, error_code: code)
      end
    end
  end
end
