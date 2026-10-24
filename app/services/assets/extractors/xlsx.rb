# frozen_string_literal: true

require "zip"
require "nokogiri"

module Assets
  module Extractors
    # XLSX extraction: workbook + sheet names, bounded rows (200/sheet) and
    # cells (30/row) for the first 10 sheets. Cell formulas are never
    # evaluated — only cached values and shared strings are read.
    class Xlsx
      NS = { "x" => "http://schemas.openxmlformats.org/spreadsheetml/2006/main" }.freeze
      MAX_SHEETS = 10
      MAX_ROWS = 200
      MAX_COLS = 30

      class << self
        def call(asset)
          bytes = asset.file.download
          raise ExtractionFailure.new(:malformed_archive) unless bytes.b.start_with?("PK\x03\x04")

          sheet_names = []
          shared_strings = []
          worksheets = []

          stream = Zip::InputStream.new(StringIO.new(bytes.b))
          while (entry = stream.get_next_entry)
            case entry.name
            when "xl/workbook.xml"
              sheet_names = workbook_sheet_names(stream.read)
            when "xl/sharedStrings.xml"
              shared_strings = shared_strings_for(stream.read)
            when /\Axl\/worksheets\/sheet\d+\.xml\z/
              worksheets << stream.read
            end
          end
          stream.close

          worksheets = worksheets.first(MAX_SHEETS)
          sheets = worksheets.each_with_index.map do |xml, i|
            name = sheet_names[i] || "sheet#{i + 1}"
            parse_sheet(xml, shared_strings).merge(name: name)
          end
          preview = sheets.first ? preview_of(sheets.first) : ""

          {
            content: preview.first(50_000).presence,
            meta:   { sheets: sheets, sheets_total: sheets.size, extractor: "xlsx" }
          }
        rescue Zip::Error
          raise ExtractionFailure.new(:malformed_archive)
        end

        private

        def workbook_sheet_names(workbook_xml)
          doc = Nokogiri::XML(workbook_xml)
          doc.xpath("//x:sheet", NS).map { |s| s["name"].to_s }
        end

        def shared_strings_for(shared_xml)
          doc = Nokogiri::XML(shared_xml)
          doc.xpath("//x:si", NS).map { |si| si.xpath(".//x:t", NS).text.to_s }
        end

        def parse_sheet(sheet_xml, shared)
          doc = Nokogiri::XML(sheet_xml)
          rows = doc.xpath(".//x:row", NS)
          bounded = rows.first(MAX_ROWS).map { |row| bounded_cells(row, shared) }

          {
            rows: rows.size,
            cols: bounded.map(&:size).max || 0,
            truncated: rows.size > MAX_ROWS,
            sample_rows: bounded.first(3)
          }
        end

        # Formula cells: stored cached value only (the <x:f> formula element
        # is deliberately never read or evaluated).
        def bounded_cells(row, shared)
          row.xpath(".//x:c", NS).first(MAX_COLS).map do |cell|
            cached = cell.xpath(".//x:v", NS).first&.text.to_s
            next "" if cached.empty?

            if cell["t"] == "s"
              shared[cached.to_i].to_s.first(200)
            else
              cached.first(200)
            end
          end
        end

        def preview_of(sheet)
          out = +"#{sheet[:name]}: #{sheet[:rows]} rows"
          Array(sheet[:sample_rows]).first(3).each do |cells|
            out << "\n" << cells.join(" | ").first(400)
          end
          out
        end
      end
    end
  end
end
