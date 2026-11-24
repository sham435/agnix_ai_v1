# frozen_string_literal: true

require "net/http"
require "json"

module Integrations
  # Fixed provider URLs are supplied only by adapters; redirects are never followed.
  class BoundedJsonRequest
    MAX_BYTES = 1_000_000
    class Rejected < StandardError; end

    def self.call(uri:, request:, timeout: 20)
      seconds = timeout.to_f.clamp(0.01, 20)
      body = +""
      Timeout.timeout(seconds) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: [ 5, seconds ].min,
                       read_timeout: [ 10, seconds ].min, write_timeout: [ 5, seconds ].min) do |http|
          http.max_retries = 0
          http.request(request) do |response|
            raise Rejected unless response.is_a?(Net::HTTPSuccess)
            raise Rejected if response["content-length"].to_i > MAX_BYTES

            response.read_body do |chunk|
              raise Rejected if body.bytesize + chunk.bytesize > MAX_BYTES

              body << chunk
            end
          end
        end
      end
      parsed = JSON.parse(body)
      raise Rejected unless parsed.is_a?(Hash)

      parsed
    end
  end
end
