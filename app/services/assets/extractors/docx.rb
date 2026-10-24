# frozen_string_literal: true

require "zip"
require "nokogiri"

module Assets
  module Extractors
    # DOCX extraction via the OOXML zip package: paragraphs and tables with
    # row/cell counts. Bounded. Nothing is executed — XML is only read.
    class Docx
      WORD_NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze
      MAX_PARAGRAPHS = 5_000
      MAX_TEXT = BOUNDED_CONTENT_CHARS

      class << self
        def call(asset)
          bytes = asset.file.download
          raise ExtractionFailure.new(:malformed_archive) unless bytes.b.start_with?("PK\x03\x04")

          doc_content = find_entry_content(bytes, "word/document.xml")
          raise ExtractionFailure.new(:corrupt_document) if doc_content.nil?

          doc = Nokogiri::XML(doc_content)
          paragraphs = doc.xpath("//w:p", WORD_NS).first(MAX_PARAGRAPHS)
          p_texts = paragraphs.map { |p| p.xpath(".//w:t", WORD_NS).text.to_s.strip }.reject(&:blank?)
          tables = doc.xpath("//w:tbl", WORD_NS).first(50).map do |tbl|
            {
              rows:  tbl.xpath(".//w:tr", WORD_NS).size,
              cells: tbl.xpath(".//w:tc", WORD_NS).size
            }
          end

          content = p_texts.join("\n").first(MAX_TEXT)
          { content: content, meta: { paragraphs: p_texts.size, tables: tables, extractor: "docx" } }
        rescue Zip::Error
          raise ExtractionFailure.new(:malformed_archive)
        end

        private

        # Streaming through Zip::InputStream: reads one entry's content out of
        # the archive bytes without materializing the whole zip graph.
        def find_entry_content(bytes, entry_name)
          content = nil
          stream = Zip::InputStream.new(StringIO.new(bytes.b))
          loop do
            entry = stream.get_next_entry
            break if entry.nil?
            if entry.name == entry_name
              content = stream.read
            end
          end
          content
        ensure
          stream&.close
        end
      end
    end
  end
end
