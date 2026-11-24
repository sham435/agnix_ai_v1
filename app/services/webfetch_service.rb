# frozen_string_literal: true

require "commonmarker"
require "erb"
require "httparty"
require "ipaddr"
require "json"
require "nokogiri"
require "resolv"
require "set"
require "timeout"
require "uri"

class WebfetchService
  MAX_URL_BYTES = 2_048
  MAX_RESPONSE_BYTES = 2.megabytes
  MAX_OUTPUT_BYTES = 250.kilobytes
  MAX_REDIRECTS = 5
  MAX_DOM_NODES = 20_000
  MAX_DOM_DEPTH = 100
  USER_REQUESTS_PER_MINUTE = 20
  ORGANIZATION_REQUESTS_PER_MINUTE = 60
  FORMATS = %w[markdown text html].freeze
  REDIRECT_STATUSES = [ 301, 302, 303, 307, 308 ].freeze
  BLOCKED_HOST_SUFFIXES = %w[.localhost .local .internal .home.arpa .lan .corp].freeze
  BLOCKED_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.31.196.0/24 192.52.193.0/24 192.88.99.0/24
    192.168.0.0/16 192.175.48.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4
  ].map { |network| IPAddr.new(network) }.freeze
  IPV6_GLOBAL_UNICAST = IPAddr.new("2000::/3")
  IPV6_SPECIAL_NETWORKS = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20 5f00::/16].map { |network| IPAddr.new(network) }.freeze
  NAT64_PREFIX = IPAddr.new("64:ff9b::/96")
  TEXT_MIME_TYPES = %w[
    text/html text/plain text/markdown text/xml text/csv text/javascript
    application/xhtml+xml application/json application/ld+json application/xml
    application/rss+xml application/atom+xml application/javascript
    application/x-javascript application/yaml application/x-yaml application/toml
  ].freeze
  CHARSETS = {
    "utf-8" => Encoding::UTF_8,
    "utf8" => Encoding::UTF_8,
    "us-ascii" => Encoding::US_ASCII,
    "ascii" => Encoding::US_ASCII,
    "iso-8859-1" => Encoding::ISO_8859_1,
    "latin1" => Encoding::ISO_8859_1,
    "windows-1252" => Encoding::Windows_1252,
    "utf-16le" => Encoding::UTF_16LE,
    "utf-16be" => Encoding::UTF_16BE
  }.freeze
  ERROR_MESSAGES = {
    invalid_request: "The webfetch request is invalid.",
    not_authorized: "You are not authorized to use webfetch for this agent.",
    capability_unavailable: "Webfetch is disabled for this organization.",
    rate_limited: "Webfetch rate limit exceeded. Try again shortly.",
    abuse_control_unavailable: "Webfetch is temporarily unavailable. Try again shortly.",
    url_invalid: "The URL is invalid.",
    url_forbidden: "The URL points to a prohibited network destination.",
    dns_failed: "The URL hostname could not be resolved safely.",
    redirect_invalid: "The URL redirect is invalid.",
    downgrade_forbidden: "The URL redirect from HTTPS to HTTP is not allowed.",
    too_many_redirects: "The URL exceeded the redirect limit.",
    timeout: "The webfetch request timed out.",
    cancelled: "The webfetch request was cancelled.",
    response_too_large: "The webfetch response exceeded the size limit.",
    unsupported_content_type: "The URL returned an unsupported content type.",
    invalid_content: "The URL returned malformed or unsafe content.",
    unsafe_dom: "The URL returned content that exceeded the document safety limits.",
    http_error: "The URL returned an HTTP error.",
    network_error: "The URL could not be fetched.",
    fetch_failed: "The URL could not be fetched."
  }.freeze

  class Error < StandardError
    attr_reader :code, :details

    def initialize(code, details = {})
      @code = code.to_s
      @details = details
      super(ERROR_MESSAGES.fetch(@code.to_sym, ERROR_MESSAGES[:fetch_failed]))
    end
  end

  Response = Struct.new(:body, :uri, :headers, :status, keyword_init: true)

  class Transport
    URL_CONTROLS = /[\x00-\x20\x7f\u0080-\u009f]|\%(?:0[0-9a-f]|1[0-9a-f]|7f)/i
    REQUEST_HEADERS = {
      "User-Agent" => "Shams-Webfetch/1.0",
      "Accept" => "text/html,application/xhtml+xml,text/plain,text/markdown,application/json,application/xml;q=0.9,*/*;q=0.1",
      "Accept-Encoding" => "identity"
    }.freeze

    def initialize(timeout:, cancelled: nil)
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @cancelled = cancelled
    end

    def fetch(value)
      uri = validate_url!(value)
      redirects = 0
      downgrade = false

      loop do
        check_deadline!
        address = resolve_destination!(uri)
        # Destination policy wins over scheme policy: a prohibited redirect is
        # url_forbidden even when it also downgrades HTTPS to HTTP.
        raise Error.new(:downgrade_forbidden) if downgrade

        response = request(uri, address)
        check_deadline!

        unless REDIRECT_STATUSES.include?(response.status)
          return response if response.status.between?(200, 299)

          raise Error.new(:http_error, status: response.status)
        end

        redirects += 1
        raise Error.new(:too_many_redirects) if redirects > MAX_REDIRECTS

        location = header_value(response.headers, "location")
        raise Error.new(:redirect_invalid) if location.blank?

        next_uri = redirect_uri!(uri, location)
        downgrade = uri.scheme == "https" && next_uri.scheme == "http"
        uri = next_uri
      end
    rescue Error
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error.new(:timeout)
    rescue SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError, HTTParty::Error
      raise Error.new(:network_error)
    end

    private

    def validate_url!(value)
      raise Error.new(:url_invalid) unless value.is_a?(String) && value.bytesize.between?(1, MAX_URL_BYTES)
      raise Error.new(:url_invalid) unless value.valid_encoding? && !value.match?(URL_CONTROLS) && !value.include?("\\")

      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTP) && %w[http https].include?(uri.scheme) && uri.hostname.present? && uri.userinfo.nil?
        raise Error.new(:url_invalid)
      end

      host = uri.hostname.downcase
      raise Error.new(:url_invalid) if host.bytesize > 253 || host.include?("%") || host.match?(/[\s\/\\]/)

      uri.fragment = nil
      uri
    rescue URI::InvalidURIError, ArgumentError
      raise Error.new(:url_invalid)
    end

    def redirect_uri!(current, location)
      validate_url!(URI.join(current.to_s, location).to_s)
    rescue Error
      raise Error.new(:redirect_invalid)
    rescue URI::InvalidURIError, ArgumentError
      raise Error.new(:redirect_invalid)
    end

    def resolve_destination!(uri)
      check_deadline!
      host = uri.hostname.downcase
      canonical_host = host.delete_suffix(".")
      if %w[localhost internal].include?(canonical_host) || BLOCKED_HOST_SUFFIXES.any? { |suffix| canonical_host.end_with?(suffix) }
        raise Error.new(:url_forbidden)
      end

      addresses = resolve_addresses(host)
      raise Error.new(:dns_failed) if addresses.empty?
      raise Error.new(:url_forbidden) if addresses.any? { |address| forbidden_address?(address) }

      check_deadline!
      addresses.first.to_s
    rescue Error
      raise
    rescue Resolv::ResolvError, SocketError, ArgumentError, IPAddr::InvalidAddressError
      raise Error.new(:dns_failed)
    end

    def resolve_addresses(host)
      literal = begin
        IPAddr.new(host.include?(":") ? "[#{host}]" : host)
      rescue IPAddr::InvalidAddressError
        nil
      end
      return [ literal ] if literal

      Timeout.timeout(remaining_seconds) { Resolv.getaddresses(host) }.map { |address| IPAddr.new(address) }.uniq
    end

    def forbidden_address?(address)
      if address.ipv6? && address.ipv4_mapped?
        embedded = IPAddr.new_ntoh([ address.to_i & 0xffff_ffff ].pack("N"))
        return forbidden_address?(embedded)
      end
      if address.ipv6? && NAT64_PREFIX.include?(address)
        embedded = IPAddr.new_ntoh([ address.to_i & 0xffff_ffff ].pack("N"))
        return forbidden_address?(embedded)
      end
      return true if address.ipv6? && !IPV6_GLOBAL_UNICAST.include?(address)
      return true if address.ipv6? && IPV6_SPECIAL_NETWORKS.any? { |network| network.include?(address) }

      BLOCKED_NETWORKS.any? { |network| network.include?(address) }
    end

    def request(uri, address)
      remaining = remaining_seconds
      body = +"".b
      consume = lambda do |fragment|
        check_deadline!
        chunk = fragment.to_s.b
        raise Error.new(:response_too_large) if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

        body << chunk
      end
      options = {
        headers: REQUEST_HEADERS,
        timeout: remaining,
        open_timeout: remaining,
        follow_redirects: false,
        stream_body: true,
        max_retries: 0,
        http_proxyaddr: nil,
        connection_adapter: lambda do |request_uri, request_options|
          http = HTTParty::ConnectionAdapter.call(request_uri, request_options)
          http.ipaddr = address
          http
        end
      }
      response = HTTParty.get(uri.to_s, **options, &consume)
      enforce_declared_size!(response.headers)
      if body.empty? && response.body && !response.body.empty?
        fallback = response.body.to_s.b
        raise Error.new(:response_too_large) if fallback.bytesize > MAX_RESPONSE_BYTES

        body << fallback
      end
      Response.new(body: body, uri: uri, headers: response.headers, status: response.code.to_i)
    end

    def enforce_declared_size!(headers)
      value = header_value(headers, "content-length")
      return if value.blank?

      length = Integer(value.to_s.strip, 10)
      raise Error.new(:response_too_large) if length > MAX_RESPONSE_BYTES
      raise Error.new(:invalid_content) if length.negative?
    rescue ArgumentError
      raise Error.new(:invalid_content)
    end

    def header_value(headers, name)
      headers.to_h.each do |key, value|
        return Array(value).join(", ") if key.to_s.casecmp?(name)
      end
      nil
    end

    def remaining_seconds
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error.new(:timeout) unless remaining.positive?

      remaining
    end

    def check_deadline!
      raise Error.new(:cancelled) if @cancelled&.call
      raise Error.new(:timeout) unless remaining_seconds.positive?
    end
  end

  module ContentExtractor
    module_function

    DANGEROUS_TAGS = %w[
      script style iframe frame frameset object embed applet svg math template noscript meta link base
      form input button textarea select option img picture source video audio track canvas head title
    ].freeze
    ALLOWED_TAGS = %w[
      html body main article section nav aside header footer div span p h1 h2 h3 h4 h5 h6
      ul ol li dl dt dd blockquote pre code em strong b i u s del hr br table thead tbody tfoot
      tr th td a figure figcaption
    ].freeze
    BLOCK_TAGS = %w[
      main article section nav aside header footer div p h1 h2 h3 h4 h5 h6 ul ol li dl dt dd
      blockquote pre table thead tbody tfoot tr figure figcaption hr
    ].to_set.freeze
    TEXT_ESCAPES = /([\\`*_{}\[\]()#+\-.!|>])/

    def extract(body, headers, format:, final_url:)
      text = decode(body, charset_from(headers))
      mime = mime_from(headers, text)
      return extract_json(text, format) if json_mime?(mime)
      return extract_xml(text, mime, format, final_url: final_url) if xml_mime?(mime)

      html = if html_mime?(mime)
               text
      elsif markdown_mime?(mime)
               Commonmarker.to_html(text, options: { extensions: %i[TABLE STRIKETHROUGH TASKLIST] })
      else
               pre_html(text)
      end
      document = sanitize_html(html, final_url: final_url)
      render_document(document, format)
    rescue JSON::ParserError, JSON::NestingError, Nokogiri::XML::SyntaxError, EncodingError
      raise Error.new(:invalid_content)
    end

    def extract_json(text, format)
      JSON.parse(text, max_nesting: 100)
      render_non_html(text, "json", format)
    end

    def extract_xml(text, mime, format, final_url:)
      raise Error.new(:invalid_content) if text.match?(/<!DOCTYPE|<!ENTITY/i)

      if mime == "application/xhtml+xml"
        document = sanitize_html(text, final_url: final_url)
        return render_document(document, format)
      end

      Nokogiri::XML::Document.parse(text, options: Nokogiri::XML::ParseOptions::NONET)
      render_non_html(text, "xml", format)
    end

    def render_document(document, format)
      case format
      when "html" then render_html(document)
      when "text" then truncate(plain_text(document))
      else truncate(markdown_text(document))
      end
    end

    def render_html(document)
      html = document.to_html
      return [ html, false ] if html.bytesize <= MAX_OUTPUT_BYTES

      plain = truncate(plain_text(document), MAX_OUTPUT_BYTES / 2).first
      render_pre_html(plain)
    end

    def render_non_html(text, language, format)
      case format
      when "html" then render_pre_html(text)
      when "text" then truncate(text)
      else fenced_code(text, language)
      end
    end

    def sanitize_html(html, final_url:)
      raise Error.new(:unsafe_dom) if html.to_s.count("<") > MAX_DOM_NODES

      document = Nokogiri::HTML5.fragment(html.to_s, max_errors: 20)
      enforce_dom_bounds!(document)
      document.css(DANGEROUS_TAGS.join(",")).each(&:remove)
      document.traverse do |node|
        node.remove if node.comment? || node.processing_instruction?
        next unless node.element?

        name = node.name.downcase
        unless ALLOWED_TAGS.include?(name)
          node.unwrap
          next
        end
        node.remove if name == "a" && node.content.strip.empty?
        next if node.parent.nil?

        sanitize_attributes!(node, final_url)
      end
      document
    end

    def enforce_dom_bounds!(document)
      count = 0
      stack = [ [ document, 0 ] ]
      while (entry = stack.pop)
        node, depth = entry
        count += 1
        raise Error.new(:unsafe_dom) if count > MAX_DOM_NODES || depth > MAX_DOM_DEPTH

        stack.concat(node.children.map { |child| [ child, depth + 1 ] })
      end
    end

    def sanitize_attributes!(node, final_url)
      node.attribute_nodes.each do |attribute|
        name = attribute.name.downcase
        keep = if name == "href" && node.name == "a"
                 safe_href(attribute.value, final_url)
        elsif name == "title"
                 attribute.value.gsub(/[\x00-\x1f\x7f]/, "").byteslice(0, 500)
        elsif %w[colspan rowspan].include?(name) && %w[td th].include?(node.name)
                 attribute.value.match?(/\A[1-9][0-9]{0,3}\z/) ? attribute.value : nil
        end
        keep ? node[attribute.name] = keep : node.remove_attribute(attribute.name)
      end
    end

    def safe_href(value, final_url)
      candidate = value.to_s.strip
      return nil if candidate.blank? || candidate.match?(/[\x00-\x20\x7f\u0080-\u009f]/)

      compact = candidate.gsub(/[\x00-\x20\x7f]+/, "").downcase
      return nil if compact.match?(/\A(?:javascript|vbscript|data|file):/)

      uri = URI.join(final_url, candidate)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::MailTo)

      uri.to_s
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def plain_text(document)
      buffer = +""
      append_plain_text(document, buffer)
      buffer.gsub(/[ \t]+/, " ").gsub(/\r\n?/, "\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def append_plain_text(node, buffer)
      if node.text?
        buffer << node.text
      elsif node.name == "br"
        buffer << "\n"
      else
        block = node.element? && BLOCK_TAGS.include?(node.name)
        buffer << "\n" if block
        node.children.each { |child| append_plain_text(child, buffer) }
        buffer << "\n" if block
      end
    end

    def markdown_text(document)
      markdown_node(document).strip.gsub(/\n{3,}/, "\n\n")
    end

    def markdown_node(node)
      return markdown_escape(node.text) if node.text?
      return "" if node.comment? || node.processing_instruction?
      return markdown_children(node) unless node.element?

      case node.name
      when "h1", "h2", "h3", "h4", "h5", "h6"
        "#{"#" * node.name.delete_prefix("h").to_i} #{markdown_children(node).strip}\n\n"
      when "p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "figure", "figcaption"
        "#{markdown_children(node).strip}\n\n"
      when "br" then "  \n"
      when "hr" then "---\n\n"
      when "strong", "b" then "**#{markdown_children(node).strip}**"
      when "em", "i" then "*#{markdown_children(node).strip}*"
      when "del", "s" then "~~#{markdown_children(node).strip}~~"
      when "code"
        return "\n#{fenced_code(node.text, "").first}\n" if node.parent&.name == "pre"

        fence = "`" * ([ 1, node.text.scan(/`+/).map(&:length).max.to_i + 1 ].max)
        "#{fence}#{node.text}#{fence}"
      when "pre" then "#{fenced_code(node.text, "").first}\n\n"
      when "blockquote"
        markdown_children(node).strip.lines.map { |line| "> #{line}" }.join
      when "ul", "ol"
        markdown_list(node)
      when "li" then markdown_children(node)
      when "a"
        label = markdown_children(node).strip
        href = node["href"]
        href ? "[#{label}](#{markdown_destination(href)})" : label
      when "table" then markdown_table(node)
      when "tr" then "#{markdown_children(node).strip}\n"
      when "th", "td" then "#{markdown_children(node).strip} | "
      else markdown_children(node)
      end
    end

    def markdown_children(node)
      node.children.map { |child| markdown_node(child) }.join
    end

    def markdown_list(node)
      ordered = node.name == "ol"
      node.children.select { |child| child.name == "li" }.each_with_index.map do |item, index|
        marker = ordered ? "#{index + 1}." : "-"
        body = markdown_children(item).strip
        body.lines.each_with_index.map { |line, line_index| line_index.zero? ? "#{marker} #{line}" : "  #{line}" }.join
      end.join("\n") + "\n\n"
    end

    def markdown_table(node)
      rows = node.css("tr").map do |row|
        row.css("th,td").map { |cell| markdown_children(cell).strip.gsub("|", "\\|") }
      end
      return "" if rows.empty?

      width = rows.map(&:length).max
      rows << Array.new(width, "---") if rows.first&.length == width
      rows.map { |row| "| #{row.join(" | ")} |" }.join("\n") + "\n\n"
    end

    def markdown_destination(href)
      href.gsub(/([\\()])/) { "\\#{Regexp.last_match(1)}" }
    end

    def markdown_escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(TEXT_ESCAPES) { "\\#{Regexp.last_match(1)}" }
    end

    def header_value(headers, name)
      headers.to_h.each do |key, value|
        return Array(value).join(", ") if key.to_s.casecmp?(name)
      end
      nil
    end

    def mime_from(headers, text)
      value = header_value(headers, "content-type").to_s
      mime = value.split(";", 2).first.to_s.strip.downcase
      return mime if mime.present?

      stripped = text.lstrip
      return "application/json" if stripped.start_with?("{", "[")
      return "application/xml" if stripped.start_with?("<?xml", "<rss", "<feed")
      return "text/html" if stripped.match?(/\A(?:<!doctype\s+html|<html\b)/i)

      "text/plain"
    end

    def charset_from(headers)
      value = header_value(headers, "content-type").to_s
      return Encoding::UTF_8 if value.blank? || !value.match?(/;\s*charset\b/i)

      charsets = value.scan(/;\s*charset\s*=\s*(?:"([^"]*)"|([^;\s]*))/i).map do |quoted, bare|
        (quoted || bare).to_s.strip.downcase
      end
      raise Error.new(:invalid_content) if charsets.empty? || charsets.length > 1 || charsets.first == ""

      CHARSETS.fetch(charsets.first) { raise Error.new(:invalid_content) }
    end

    def decode(body, encoding)
      bytes = body.to_s.b.force_encoding(encoding)
      raise Error.new(:invalid_content) unless bytes.valid_encoding?

      text = bytes.encode(Encoding::UTF_8).delete_prefix("\uFEFF")
      raise Error.new(:invalid_content) if text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)

      text
    end

    def json_mime?(mime)
      mime == "application/json" || mime.end_with?("+json")
    end

    def xml_mime?(mime)
      mime == "application/xml" || mime == "text/xml" || mime.end_with?("+xml")
    end

    def html_mime?(mime)
      %w[text/html application/xhtml+xml].include?(mime)
    end

    def markdown_mime?(mime)
      %w[text/markdown text/x-markdown].include?(mime)
    end

    def supported_mime?(mime)
      TEXT_MIME_TYPES.include?(mime) || mime.start_with?("text/") || json_mime?(mime) || xml_mime?(mime)
    end

    def pre_html(text)
      "<pre>#{ERB::Util.html_escape(text)}</pre>"
    end

    def render_pre_html(text)
      escaped, truncated = truncate(ERB::Util.html_escape(text), MAX_OUTPUT_BYTES - "<pre></pre>".bytesize)
      [ "<pre>#{escaped}</pre>", truncated ]
    end

    def fenced_code(text, language)
      longest = text.to_s.scan(/`+/).map(&:length).max.to_i
      fence = "`" * [ 3, longest + 1 ].max
      prefix = "#{fence}#{language}\n"
      suffix = "\n#{fence}"
      budget = MAX_OUTPUT_BYTES - prefix.bytesize - suffix.bytesize
      content, truncated = truncate(text, budget)
      [ "#{prefix}#{content}#{suffix}", truncated ]
    end

    def truncate(text, limit = MAX_OUTPUT_BYTES)
      value = text.to_s
      return [ value, false ] if value.bytesize <= limit

      # Drop an incomplete trailing code point instead of scrubbing it: scrub
      # can replace one partial byte with a three-byte U+FFFD and exceed the cap.
      prefix = value.b.byteslice(0, limit).force_encoding(Encoding::UTF_8)
      prefix = prefix.byteslice(0, prefix.bytesize - 1) until prefix.valid_encoding?
      [ prefix, true ]
    end
  end

  class << self
    def call(url:, format: "markdown", timeout: 20, user:, organization:, cancelled: nil)
      return failure(:not_authorized) unless authorized?(user, organization)
      return failure(:capability_unavailable) unless Capabilities::Registry.available?("webfetch", organization: organization)
      return failure(:invalid_request) unless valid_request?(url, format, timeout)

      consume_abuse_control!(user, organization)
      response = Transport.new(timeout: timeout, cancelled: cancelled).fetch(url)
      mime = ContentExtractor.send(:mime_from, response.headers, response.body.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace))
      unless ContentExtractor.send(:supported_mime?, mime)
        raise Error.new(:unsupported_content_type)
      end

      content, truncated = ContentExtractor.extract(response.body, response.headers, format: format, final_url: response.uri.to_s)
      {
        ok: true,
        content: content,
        format: format,
        url: url,
        final_url: response.uri.to_s,
        content_type: mime,
        bytes: response.body.bytesize,
        truncated: truncated,
        untrusted: true
      }
    rescue Error => error
      failure(error.code, error.details)
    rescue StandardError => error
      Rails.logger.warn "[Webfetch] unexpected failure class=#{error.class}"
      failure(:fetch_failed)
    end

    private

    def valid_request?(url, format, timeout)
      url.is_a?(String) && url.bytesize.between?(1, MAX_URL_BYTES) && FORMATS.include?(format) &&
        timeout.is_a?(Integer) && timeout.between?(1, 120)
    end

    def authorized?(user, organization)
      user.is_a?(User) && organization.is_a?(Organization) &&
        (user.owner?(organization) || user.organizations.exists?(id: organization.id))
    end

    def consume_abuse_control!(user, organization)
      bucket = Time.now.to_i / 60
      limits = {
        "webfetch:user:#{user.id}:#{bucket}" => USER_REQUESTS_PER_MINUTE,
        "webfetch:org:#{organization.id}:#{bucket}" => ORGANIZATION_REQUESTS_PER_MINUTE
      }
      limits.each do |key, limit|
        count = Rails.cache.increment(key, 1, expires_in: 61)
        raise Error.new(:abuse_control_unavailable) if count.nil?
        raise Error.new(:rate_limited) if count > limit
      end
    rescue Error
      raise
    rescue StandardError => error
      Rails.logger.warn "[Webfetch] abuse-control failure class=#{error.class}"
      raise Error.new(:abuse_control_unavailable)
    end

    def failure(code, details = {})
      { ok: false, error_code: code.to_s, error: ERROR_MESSAGES.fetch(code.to_s.to_sym, ERROR_MESSAGES[:fetch_failed]) }.merge(details)
    end
  end
end
