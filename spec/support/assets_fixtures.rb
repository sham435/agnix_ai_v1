# frozen_string_literal: true

require "zip"
require "open3"

# In-spec fixture builders for asset extraction tests. Uses RubyZip to
# construct minimal-but-valid DOCX/XLSX packages; hand-written REAL PDFs (valid xref) for pdf-reader, and
# Poppler/Tesseract helpers for OCR integration tests.
module AssetsFixtures
  def text_file(content)
    StringIO.new(content)
  end

  # File-based Zip::OutputStream (not write_buffer in memory): writes a
  # reliable central directory for fixture packages. Returns the raw bytes
  # as a binary String (so Tempfile#write in specs stores real bytes).
  def build_zip(entries)
    Tempfile.create([ "shams-fixture", ".zip" ]) do |tmp|
      Zip::OutputStream.open(tmp.path) do |zos|
        entries.each do |name, content|
          zos.put_next_entry(name)
          zos.write(content.b)
        end
      end
      File.binread(tmp.path)
    end
  end

  def build_docx(doc_xml)
    build_zip("word/document.xml" => doc_xml)
  end

  def build_xlsx(xlsx_files)
    build_zip(xlsx_files)
  end

  def docx_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          <w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>
          <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
          <w:tbl>
            <w:tr><w:tc><w:r><w:t>Name</w:t></w:r></w:tc><w:tc><w:r><w:t>Role</w:t></w:r></w:tc></w:tr>
            <w:tr><w:tc><w:r><w:t>Nova</w:t></w:r></w:tc><w:tc><w:r><w:t>Engineer</w:t></w:r></w:tc></w:tr>
          </w:tbl>
        </w:body>
      </w:document>
    XML
  end

  # A REAL minimal single-page PDF: valid xref + trailer so pdf-reader can
  # parse it. text: string drawn as Helvetica text ops. Pass text: nil for
  # a scanned-style page (no text operators).
  def build_pdf(text)
    content = text ? "BT /F1 14 Tf 72 720 Td (#{text}) Tj ET" : ""
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> " \
        "/Contents 5 0 R /MediaBox [0 0 612 792] >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
    ]

    out = +"%PDF-1.4\n"
    offsets = [ 0 ]
    objects.each_with_index do |body, i|
      offsets << out.bytesize
      out << "#{i + 1} 0 obj #{body} endobj\n"
    end
    xref_pos = out.bytesize
    out << "xref\n0 6\n0000000000 65535 f \n"
    offsets[1..].each { |off| out << format("%010d 00000 n \n", off) }
    out << "trailer << /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF"
    out
  end

  # Renders a PDF page to PNG via Poppler (pdftoppm) and returns the bytes —
  # used for end-to-end OCR specs. Returns nil when Poppler is not installed
  # so callers can skip honestly rather than fail.
  def render_pdf_page_to_png(pdf_path)
    _out, _err, status = Open3.capture3("pdftoppm", "-r", "150", "-png", pdf_path, "/tmp/shams-render-page")
    return nil unless status.success?

    png = Dir.glob("/tmp/shams-render-page-*.png").min_by { |f| f[/-(\d+)\.png$/, 1].to_i }
    return nil unless png && File.size(png).positive?

    data = File.binread(png)
    File.delete(png)
    data
  end

  def xlsx_files(rows_xml = default_xlsx_rows)
    {
      "xl/workbook.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <x:workbook xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <x:sheets>
            <x:sheet name="Grades" sheetId="1" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
            <x:sheet name="Sheet2" sheetId="2" r:id="rId2" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>
          </x:sheets>
        </x:workbook>
      XML
      "xl/sharedStrings.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <x:sst xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
          <x:si><x:t>Nova</x:t></x:si>
          <x:si><x:t>Ada</x:t></x:si>
          <x:si><x:t>B</x:t></x:si>
        </x:sst>
      XML
      "xl/worksheets/sheet1.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <x:sheetData>#{rows_xml}</x:sheetData>
        </x:worksheet>
      XML
      "xl/worksheets/sheet2.xml" => <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <x:sheetData><x:row r="1"><x:c t="n"><x:v>42</x:v></x:c></x:row></x:sheetData>
        </x:worksheet>
      XML
    }
  end

  def default_xlsx_rows
    <<~ROWS
      <x:row r="1">
        <x:c t="s"><x:v>0</x:v></x:c><x:c t="n"><x:v>99</x:v><x:f>A1*2</x:f></x:c>
      </x:row>
      <x:row r="2">
        <x:c t="s"><x:v>1</x:v></x:c><x:c t="n"><x:v>88</x:v></x:c>
      </x:row>
    ROWS
  end
end

RSpec.configure { |c| c.include AssetsFixtures }
