require "net/http"
require "uri"
require "shellwords"

module Workspaces
  # Loopback HTTP client for the workspace manager. This is the only place Rails
  # talks to Docker, and it talks to it over a socket it does not have.
  class ManagerClient
    OPEN_TIMEOUT = 3
    SHORT_READ_TIMEOUT = 30
    LONG_READ_TIMEOUT = 300
    LONG_PATHS = %w[/install /export /preview /exec].freeze
    # Header forwarding for previews: hop-by-hop noise, and anything that could
    # tell the workspace server who the real visitor was.
    DROPPED_REQUEST_HEADERS = %w[host content-length connection x-shams-token accept-encoding
                                 cookie authorization].freeze
    DROPPED_RESPONSE_HEADERS = %w[content-length transfer-encoding connection set-cookie
                                  content-encoding].freeze
    METHODS = {
      "GET" => Net::HTTP::Get, "HEAD" => Net::HTTP::Head, "POST" => Net::HTTP::Post,
      "PUT" => Net::HTTP::Put, "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete
    }.freeze

    class << self
      def base_url
        (ENV["SHAMS_WS_MANAGER_URL"].presence || "http://127.0.0.1:3005").chomp("/")
      end

      def token
        ENV["SHAMS_WS_MANAGER_TOKEN"].presence || token_from_env_file
      end

      def get(path, query = {})
        request(uri_for(path, query))
      end

      def post(path, body = {}, query = {})
        request(uri_for(path, query), :post, body)
      end

      def delete(path, query = {})
        request(uri_for(path, query), :delete)
      end

      # Preview forwarding is not JSON: the manager hands back exactly what the
      # workspace's own server said, so this returns status, headers and body.
      def raw(method, path, query: {}, headers: {}, body: nil)
        verb = method.to_s.upcase
        raise Rejected.new(405, "preview method not allowed") unless METHODS.key?(verb)

        uri = uri_for(path, query)
        request = METHODS[verb].new(uri)
        headers.each do |key, value|
          next if DROPPED_REQUEST_HEADERS.include?(key.to_s.downcase)
          request[key.to_s] = Array(value).join(", ")
        end
        request["X-Shams-Token"] = token
        request.body = body if body

        response = start(uri, LONG_READ_TIMEOUT) { |session| session.request(request) }
        [
          response.code.to_i,
          response.to_hash.filter_map { |k, v| [ k, Array(v) ] unless DROPPED_RESPONSE_HEADERS.include?(k) }.to_h,
          response.body.to_s
        ]
      end

      private

      # The manager's bearer token lives in the same local env file as the rest
      # of this deployment's secrets, so nothing has to be copied into the repo.
      def token_from_env_file
        path = File.expand_path(ENV["SHAMS_WS_ENV_FILE"].presence || "~/.config/shams/workspaces.env")
        return nil unless File.readable?(path)

        File.foreach(path) do |line|
          key, value = line.strip.split("=", 2)
          return value if key == "SHAMS_WS_TOKEN" && value.present?
        end
        nil
      end

      def uri_for(path, query)
        uri = URI.parse(base_url)
        uri.path = path.to_s.split("/", -1).map { |part| encode(part) }.join("/")
        uri.query = URI.encode_www_form(query) if query.any?
        uri
      end

      # A workspace file name is any string the user typed, spaces included, so
      # each path segment goes on the wire percent-encoded and arrives identical.
      def encode(segment)
        return "" if segment.empty?
        return segment if segment.match?(/\A[a-zA-Z0-9._~!$&'()*+,;=:@-]+\z/)

        URI.encode_www_form_component(segment).gsub("+", "%20")
      end

      def start(uri, read_timeout)
        raise Unavailable, "workspace manager token is not configured" if token.blank?

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = read_timeout
        http.write_timeout = read_timeout if http.respond_to?(:write_timeout=)
        http.start { |session| yield(session) }
      rescue SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout,
             Net::WriteTimeout, EOFError, IOError, Timeout::Error => e
        raise Unavailable, "workspace manager is not reachable (#{e.class})"
      end

      def request(uri, method = :get, body = nil)
        timeout = LONG_PATHS.any? { |suffix| uri.path.end_with?(suffix) } ? LONG_READ_TIMEOUT : SHORT_READ_TIMEOUT
        response = start(uri, timeout) { |session| session.request(build_request(uri, method, body)) }
        decode(response)
      end

      def build_request(uri, method, body)
        request = METHODS[method.to_s.upcase].new(uri)
        if body
          request.body = body.to_json
          request["content-type"] = "application/json"
        end
        request["X-Shams-Token"] = token
        request["accept"] = "application/json"
        request
      end

      def decode(response)
        payload = response.body.to_s
        parsed = payload.blank? ? {} : JSON.parse(payload)
        status = response.code.to_i
        if status >= 400
          raise Rejected.new(status, parsed["error"] || "workspace manager refused the request")
        end
        parsed
      rescue JSON::ParserError
        raise Unavailable, "workspace manager returned unreadable data (HTTP #{response.code})"
      end
    end
  end
end
