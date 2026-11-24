# frozen_string_literal: true

module Llm
  module SecureHttp
    module_function

    def post(connection, path, body:, headers: {}, &block)
      url = connection.endpoint_for(path)
      payload = body.to_json
      if payload.bytesize > connection.max_request_bytes
        raise ProviderError.new("The model request exceeds the configured size limit.", code: "request_too_large")
      end
      perform(:post, connection, url, payload, headers: headers, &block)
    end

    def get(connection, path, query: {}, headers: {})
      url = connection.endpoint_for(path, query: query)
      perform(:get, connection, url, headers: headers)
    end

    def perform(method, connection, url, payload = nil, headers: {}, &block)
      request_headers = connection.headers.merge(headers.transform_keys(&:to_s)).compact
      if request_headers.any? { |name, value| name.to_s.match?(/[\r\n]/) || value.to_s.match?(/[\r\n]/) }
        raise ProviderError.new("Invalid provider header.", code: "configuration_invalid")
      end
      options = {
        headers: request_headers,
        timeout: connection.read_timeout,
        open_timeout: connection.open_timeout,
        follow_redirects: false,
        http_proxyaddr: nil,
        stream_body: block_given?
      }
      options[:body] = payload if payload
      if connection.respond_to?(:pinned_address_for) && (address = connection.pinned_address_for(url))
        options[:connection_adapter] = lambda do |request_uri, request_options|
          http = HTTParty::ConnectionAdapter.call(request_uri, request_options)
          http.ipaddr = address
          http
        end
      end
      streaming = block_given?
      limit = streaming ? connection.max_stream_bytes : connection.max_response_bytes
      bytes = 0
      consume_fragment = lambda do |chunk|
        bytes += chunk.to_s.bytesize
        if bytes > limit
          message = streaming ? "The model stream exceeded the configured size limit." :
            "The provider response exceeded the configured size limit."
          raise ProviderError.new(message, code: "response_too_large")
        end
        block.call(chunk) if streaming
      end
      response = if method == :get
                   HTTParty.get(url, **options, &consume_fragment)
      else
                   HTTParty.post(url, **options, &consume_fragment)
      end
      enforce_response_size!(connection, response, streaming)
      response
    rescue ProviderError
      raise
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError,
           Timeout::Error, SocketError, OpenSSL::SSL::SSLError => error
      raise ProviderError.network(error)
    end

    def enforce_response_size!(connection, response, streaming)
      limit = streaming ? connection.max_stream_bytes : connection.max_response_bytes
      declared = response.headers["content-length"].to_i if response.respond_to?(:headers) && response.headers.respond_to?(:[])
      raise ProviderError.new("The provider response exceeded the configured size limit.", code: "response_too_large") if declared.to_i > limit
      return if streaming

      if response.body.to_s.bytesize > limit
        raise ProviderError.new("The provider response exceeded the configured size limit.", code: "response_too_large")
      end
    end
  end
end
