# frozen_string_literal: true

require "tempfile"
require "open3"
require "timeout"

module Sketches
  class Create
    class RenderingUnavailable < StandardError; end

    Result = Data.define(:asset, :document, :json, :svg)

    def self.call(user:, document:)
      new(user: user, document: document).send(:call)
    end

    def self.available?
      require "vips"
      true
    rescue LoadError
      [ "/opt/homebrew/bin/rsvg-convert", "/usr/bin/rsvg-convert" ].any? { |path| File.executable?(path) }
    end

    def initialize(user:, document:)
      @user = user
      @document = document
    end

    private

    def call
      canonical = Document.call(document: @document)
      png = rasterize(canonical)
      Tempfile.create([ "sketch", ".png" ]) do |file|
        file.binmode
        file.write(png)
        file.rewind
        upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "sketch.png", type: "image/png")
        asset = Assets::Ingest.call(user: @user, upload: upload).asset
        asset.with_lock do
          # First provenance wins when distinct documents render identical bytes.
          unless asset.metadata.key?("sketch")
            asset.update!(metadata: asset.metadata.merge("sketch" => { "json" => canonical.json, "svg" => canonical.svg }))
          end
        end
        Result.new(asset: asset, document: canonical.document, json: canonical.json, svg: canonical.svg)
      end
    end

    def rasterize(canonical)
      require "vips"
      # Only our generated SVG reaches librsvg: no user markup, resource URLs,
      # styles, fonts, entities or external references are accepted by Document.
      image = Vips::Image.svgload_buffer(canonical.svg, dpi: 72)
      unless image.width == canonical.document.fetch("width") && image.height == canonical.document.fetch("height")
        raise RenderingUnavailable, "SVG renderer returned unexpected dimensions"
      end
      image.pngsave_buffer(strip: true)
    rescue LoadError
      executable = [ "/opt/homebrew/bin/rsvg-convert", "/usr/bin/rsvg-convert" ].find { |path| File.executable?(path) }
      raise RenderingUnavailable, "Install libvips or librsvg to enable PNG previews" unless executable

      png = nil
      Open3.popen3(executable, "--format=png") do |input, output, error, thread|
        output.binmode
        begin
          Timeout.timeout(10) do
            input.write(canonical.svg)
            input.close
            png = output.read(5_000_001)
            raise RenderingUnavailable, "PNG rendering failed" unless thread.value.success? && png.bytesize <= 5_000_000
          end
        ensure
          unless thread.join(0)
            Process.kill("KILL", thread.pid)
            thread.join
          end
          error.close
        end
      end
      raise RenderingUnavailable, "PNG rendering failed" unless png.start_with?("\x89PNG\r\n\x1a\n".b)

      png
    rescue Vips::Error, Timeout::Error
      raise RenderingUnavailable, "Local SVG rendering failed"
    end
  end
end
