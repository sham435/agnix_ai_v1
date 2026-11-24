require "net/http"
require "uri"

module Tunnel
  class Status
    URL_PATTERN = %r{\Ahttps://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com\z}
    MAX_STATE_AGE = 24.hours

    def initialize(state_path: ENV.fetch("SHAMS_TUNNEL_URL_FILE", File.expand_path("~/.config/shams/tunnel_url")))
      @state_path = state_path
    end

    def call
      result = {
        status: "unknown", verified_url: nil, hostname: nil, supervisor_status: "unknown",
        last_verified_at: nil, last_changed_at: nil, last_health_check: nil,
        web_service_health: "unknown", worker_service_health: "unknown", error_code: nil
      }
      return result.merge(status: "unavailable", error_code: "supervisor_state_unavailable") unless File.file?(@state_path)
      return result.merge(error_code: "invalid_supervisor_url") if File.size(@state_path) > 512

      url = File.read(@state_path, 513).strip
      return result.merge(error_code: "invalid_supervisor_url") unless URL_PATTERN.match?(url)

      changed_at = File.mtime(@state_path)
      result[:last_changed_at] = changed_at.iso8601
      return result.merge(error_code: "stale_supervisor_url") if changed_at < MAX_STATE_AGE.ago || changed_at > Time.current

      uri = URI.parse("#{url}/login")
      http = Net::HTTP.new(uri.host, 443, nil)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = 5
      response_code = nil
      http.request(Net::HTTP::Get.new(uri.request_uri)) { |response| response_code = response.code }
      result[:last_health_check] = Time.current.iso8601
      unless %w[200 302].include?(response_code)
        return result.merge(status: "unavailable", web_service_health: "unhealthy", error_code: "public_route_unhealthy")
      end
      unless File.read(@state_path, 513).strip == url && File.mtime(@state_path) == changed_at
        return result.merge(error_code: "supervisor_state_changed")
      end

      result.merge(status: "degraded", verified_url: url, hostname: uri.host,
        last_verified_at: Time.current.iso8601, web_service_health: "healthy",
        error_code: "worker_health_unverified")
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError
      result.merge(status: "unavailable", error_code: "supervisor_verification_unavailable")
    end
  end
end
