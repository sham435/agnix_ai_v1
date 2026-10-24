# frozen_string_literal: true

require "csv"

module Assets
  module Extractors
    # CSV extraction: column names, bounded rows (200) and cells (30/row),
    # plus a short preview. Malformed CSV fails deterministically with
    # `parse_error`. Formulas are not applicable; nothing is executed.
    class Csv
      MAX_ROWS = 200
      MAX_COLS = 30
      PREVIEW_ROWS = 5

      class << self
        def call(asset)
          text = asset.file.download.force_encoding("UTF-8").scrub

          headers = Csv.headers(text)
          rows = Csv.bounded_rows(text)
          preview = text.lines.first(PREVIEW_ROWS + 1).join

          {
            content: preview.first(BOUNDED_CONTENT_CHARS),
            meta:   { columns: headers, rows: rows, truncated: rows.size >= MAX_ROWS, extractor: "csv" }
          }
        end

        def headers(text)
          first_line = text.lines.first.to_s.strip
          CSV.parse_line(first_line)&.first(MAX_COLS)
        rescue CSV::MalformedCSVError
          raise ExtractionFailure.new(:parse_error)
        end

        def bounded_rows(text)
          rows = []
          CSV.parse(text) do |row|
            break if rows.size >= MAX_ROWS

            rows << row.first(MAX_COLS).map { |c| c.to_s.first(200) }
          end
          rows
        rescue CSV::MalformedCSVError
          raise ExtractionFailure.new(:parse_error)
        end
      end
    end
  end
end
