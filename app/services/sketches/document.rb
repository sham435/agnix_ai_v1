# frozen_string_literal: true

require "json"
require "cgi"

module Sketches
  class Document
    class InvalidDocument < StandardError; end

    Result = Data.define(:document, :json, :svg)
    PALETTE = %w[black white red green blue yellow orange purple gray transparent].freeze
    FIELDS = {
      "rect" => %w[x y width height fill],
      "circle" => %w[cx cy r fill],
      "line" => %w[x1 y1 x2 y2 stroke stroke_width],
      "text" => %w[x y text fill font_size]
    }.freeze

    def self.call(document:)
      new(document: document).send(:call)
    end

    def initialize(document:)
      @input = document
    end

    private

    def call
      input = object(@input, %w[width height shapes])
      width = dimension(input.fetch("width"))
      height = dimension(input.fetch("height"))
      shapes = input.fetch("shapes")
      invalid! unless shapes.is_a?(Array) && shapes.size <= 100
      document = { "width" => width, "height" => height, "shapes" => shapes.map { |shape| primitive(shape) } }
      svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">)
      svg += document.fetch("shapes").map { |shape| element(shape) }.join
      Result.new(document: document, json: JSON.generate(document), svg: svg + "</svg>")
    rescue KeyError
      invalid!
    end

    def object(value, fields)
      invalid! unless value.is_a?(Hash) && value.size == fields.size
      normalized = {}
      value.each do |key, entry|
        invalid! unless key.is_a?(String) || key.is_a?(Symbol)
        name = key.to_s
        invalid! unless fields.include?(name) && !normalized.key?(name)
        normalized[name] = entry
      end
      normalized
    end

    def dimension(value)
      invalid! unless value.is_a?(Integer) && value.between?(1, 1024)
      value
    end

    def primitive(value)
      invalid! unless value.is_a?(Hash)
      type = value["type"] || value[:type]
      fields = FIELDS[type]
      invalid! unless fields
      input = object(value, [ "type", *fields ])
      fields.each_with_object({ "type" => type }) do |field, result|
        result[field] = case field
        when "fill", "stroke" then color(input.fetch(field))
        when "text" then text(input.fetch(field))
        else number(input.fetch(field), field)
        end
      end
    end

    def number(value, field)
      invalid! unless (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(0, 1024)
      invalid! if %w[font_size stroke_width].include?(field) && !value.between?(1, 128)
      value == value.to_i ? value.to_i : value
    end

    def color(value)
      invalid! unless value.is_a?(String) && (PALETTE.include?(value) || /\A#[0-9a-fA-F]{6}\z/.match?(value))
      value.downcase
    end

    def text(value)
      invalid! unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
      invalid! unless value.length <= 200 && !/[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/.match?(value)
      value
    end

    def element(shape)
      type = shape.fetch("type")
      attributes = shape.except("type", "text").map do |key, value|
        %(#{key.tr('_', '-')}="#{CGI.escapeHTML(value.to_s)}")
      end.join(" ")
      if type == "text"
        %(<text #{attributes} font-family="sans-serif">#{CGI.escapeHTML(shape.fetch("text"))}</text>)
      else
        %(<#{type} #{attributes}/>)
      end
    end

    def invalid!
      raise InvalidDocument, "Expected width/height (1..1024) and at most 100 strictly typed shapes"
    end
  end
end
