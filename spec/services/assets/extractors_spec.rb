# frozen_string_literal: true

# Integration-style specs: one narrative example asserts several properties.
# rubocop:disable RSpec/MultipleExpectations, RSpec/ExampleLength

require "rails_helper"
require "zip"

RSpec.describe Assets::Extractors do
  def asset_with(filename:, bytes:, category:, ext:, blob_name:)
    asset = create(:asset, filename: filename, metadata: { "category" => category, "ext" => ext })
    if blob_name
      Tempfile.create("extraction-spec-") do |f|
        f.binmode
        f.write(bytes)
        f.rewind
        asset.file.attach(io: f, filename: filename, content_type: asset.content_type)
      end
    end
    asset
  end

  describe "Text" do
    it "extracts bounded text" do
      asset = asset_with(filename: "a.rb", bytes: "puts 'hi'", category: "text", ext: "rb", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:content]).to include("puts 'hi'")
      expect(result[:meta][:extractor]).to eq("text")
    end

    it "rejects NUL byte binaries as unsupported" do
      asset = asset_with(filename: "b.rb", bytes: "\x00\x01binary", category: "text", ext: "rb", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:unsupported_format) }
    end
  end

  describe "Csv" do
    it "parses bounded rows and returns column names" do
      csv = (1..250).map { |i| "name#{i},score#{i}" }.join("\n")
      asset = asset_with(filename: "g.csv", bytes: "name,score\n#{csv}", category: "data", ext: "csv", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:meta][:columns]).to eq(%w[name score])
      expect(result[:meta][:rows].size).to eq(200)
      expect(result[:meta][:truncated]).to be true
      expect(result[:meta][:rows].first).to eq(%w[name score])
    end

    it "raises parse_error on malformed csv" do
      bad = "a,b\r\n\"unterminated,\" , x"
      asset = asset_with(filename: "bad.csv", bytes: bad, category: "data", ext: "csv", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:parse_error) }
    end
  end

  describe "Pdf (PDF::Reader + real OCR fallback)" do
    it "extracts text from a real text pdf with page structure" do
      # Producer-made fixture (cupsfilter) — hand-built minimal PDFs hit a
      # pdf-reader tokenizer edge on long literal strings.
      real_pdf = File.binread(Rails.root.join("spec/fixtures/files/page_text_real.pdf"))
      asset = asset_with(filename: "t.pdf", bytes: real_pdf,
                         category: "document", ext: "pdf", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:content]).to include("Dream big").and include("real print pipeline")
      expect(result[:content]).to start_with("## Page 1") # page boundaries preserved
      expect(result[:meta][:pages]).to eq(1)
      expect(result[:meta][:extraction_method]).to eq("pdf_text")
      expect(result[:meta][:truncated]).to be(false)
    end

    it "fails a scanned (text-less) page honestly when OCR yields nothing" do
      asset = asset_with(filename: "scan.pdf", bytes: build_pdf(nil),
                         category: "document", ext: "pdf", blob_name: true)

      ocr_ready = Assets::Ocr.available? && system("which pdftoppm >/dev/null 2>&1")
      code = ocr_ready ? :no_text_found : :ocr_unavailable

      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(code) }
    end

    it "OCRs a rendered text page end-to-end when tools are installed (integration)" do
      skip "tesseract/poppler not installed" unless Assets::Ocr.available? && system("which pdftoppm >/dev/null 2>&1")

      png_bytes = render_pdf_page_to_png(write_tmp_pdf(build_pdf("SHAMS OCR PIPELINE IS REAL")))
      skip "render produced no image" if png_bytes.nil?

      asset = asset_with(filename: "page.png", bytes: png_bytes, category: "image", ext: "png", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:content].to_s.downcase).to include("shams").and include("ocr")
      expect(result[:meta][:extraction_method]).to eq("ocr")
    end

    it "rejects non-pdf bytes as unsupported" do
      asset = asset_with(filename: "x.pdf", bytes: "definitely not a pdf", category: "document", ext: "pdf", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:unsupported_format) }
    end

    it "reports encrypted pdfs as parse_error (unreadable without the password)" do
      encrypted = build_pdf("secret words").sub("%PDF-1.4\n", "%PDF-1.4\n/Encrypt 9 0 R\n")
      asset = asset_with(filename: "e.pdf", bytes: encrypted, category: "document", ext: "pdf", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:parse_error) }
    end
  end

  describe "Docx" do
    it "extracts paragraphs and table structures" do
      asset = asset_with(filename: "doc.docx", bytes: build_docx(docx_xml), category: "document", ext: "docx", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:content]).to include("First paragraph").and include("Second paragraph")
      expect(result[:meta][:paragraphs]).to eq(2)
      expect(result[:meta][:tables]).to eq([ { rows: 2, cells: 4 } ])
      expect(result[:meta][:extractor]).to eq("docx")
    end

    it "raises corrupt_document when the word/document.xml entry is missing" do
      buffer = Zip::OutputStream.write_buffer do |z|
        z.put_next_entry("hello.txt")
        z.write("no word document here")
      end
      buffer.rewind
      asset = asset_with(filename: "bad.docx", bytes: buffer.read, category: "document", ext: "docx", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:corrupt_document) }
    end
  end

  describe "Xlsx" do
    it "returns sheet names with bounded rows and shared-string cells" do
      asset = asset_with(filename: "book.xlsx", bytes: build_xlsx(xlsx_files), category: "spreadsheet", ext: "xlsx", blob_name: true)
      result = described_class.run_for(asset)

      sheets = result[:meta][:sheets]
      formula_sheet = sheets.first
      expect(formula_sheet[:name]).to eq("Grades")
      expect(formula_sheet[:rows]).to eq(2)
      expect(formula_sheet[:sample_rows].first).to include("Nova", "99")

      expect(result[:meta][:sheets_total]).to eq(2)
      expect(result[:meta][:extractor]).to eq("xlsx")
    end

    it "raises malformed_archive for random bytes" do
      asset = asset_with(filename: "c.xlsx", bytes: "junk", category: "spreadsheet", ext: "xlsx", blob_name: true)
      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:malformed_archive) }
    end
  end

  describe "images (real OCR)" do
    it "extracts recognized text via tesseract when the engine is installed" do
      skip "tesseract/poppler not installed" unless Assets::Ocr.available? && system("which pdftoppm >/dev/null 2>&1")

      png_bytes = render_pdf_page_to_png(write_tmp_pdf(build_pdf("SHAMS IMAGE TEXT REPLAY")))
      skip "render produced no image" if png_bytes.nil?

      asset = asset_with(filename: "page2.png", bytes: png_bytes, category: "image", ext: "png", blob_name: true)
      result = described_class.run_for(asset)

      expect(result[:content].to_s.downcase).to include("shams")
      expect(result[:meta][:extraction_method]).to eq("ocr")
    end

    it "fails honestly when the OCR engine is missing" do
      allow(Assets::Ocr).to receive(:binary_path).and_return(nil)
      asset = asset_with(filename: "i.png", bytes: "PNGdata", category: "image", ext: "png", blob_name: true)

      expect { described_class.run_for(asset) }
        .to raise_error(Assets::Extractors::ExtractionFailure) { |e| expect(e.safe_code).to eq(:ocr_unavailable) }
    end

    it "passes recognized text through the bounded pipeline (stubbed engine)" do
      allow(Assets::Ocr).to receive(:call).and_return("recognized words here")
      asset = asset_with(filename: "i.png", bytes: "PNGdata", category: "image", ext: "png", blob_name: true)

      result = described_class.run_for(asset)

      expect(result[:content]).to eq("recognized words here")
      expect(result[:meta][:extraction_method]).to eq("ocr")
      expect(result[:meta][:truncated]).to be(false)
    end
  end

  private

  # Writes pdf bytes to a tmp file for tooling that needs a path.
  def write_tmp_pdf(bytes)
    path = Tempfile.new([ "shams-fixture", ".pdf" ]).path
    File.binwrite(path, bytes)
    path
  end
end
