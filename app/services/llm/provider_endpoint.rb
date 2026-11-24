# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "timeout"

module Llm
  module ProviderEndpoint
    DNS_TIMEOUT = 2

    module_function

    LOOPBACK_HOSTS = %w[localhost localhost.localdomain].freeze
    BLOCKED_HOST_SUFFIXES = %w[.localhost .local .internal].freeze
    BLOCKED_NETWORKS = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
      198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/96 ::ffff:0:0/96 64:ff9b::/96 64:ff9b:1::/48 100::/64 2001::/23
      2001:20::/28 2001:db8::/32 2002::/16 3fff::/20 fc00::/7 fe80::/10 fec0::/10 ff00::/8
    ].map { |network| IPAddr.new(network) }.freeze
    NAT64_PREFIX = IPAddr.new("64:ff9b::/96")

    def validate_url!(value, local: false, resolve: true, trusted_local: false)
      validate_endpoint!(value, local: local, resolve: resolve, trusted_local: trusted_local).first
    end

    def validate_endpoint!(value, local: false, resolve: true, allow_query: false, trusted_local: false)
      trusted_local &&= local
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? &&
             (allow_query || uri.query.nil?)
        message = allow_query ? "Enter a valid provider URL without credentials or fragments." :
          "Enter a valid provider base URL without credentials, query parameters, or fragments."
        raise ProviderError.new(message, code: "endpoint_invalid")
      end
      if uri.query && uri.query.bytesize > 8.kilobytes
        raise ProviderError.new("The provider URL query is too large.", code: "endpoint_invalid")
      end
      unless uri.port.between?(1, 65_535)
        raise ProviderError.new("Enter a valid provider port.", code: "endpoint_invalid")
      end
      if uri.scheme == "https" && uri.port == 80
        raise ProviderError.new("HTTPS cannot use port 80.", code: "endpoint_invalid")
      end

      host = uri.host.to_s.downcase
      local_destination = loopback?(host) || (trusted_local && docker_host?(host))
      if local
        unless local_destination
          raise ProviderError.new("The local model endpoint must use loopback or the Docker host gateway only.", code: "endpoint_forbidden")
        end
      elsif uri.scheme != "https" && !local_destination
        raise ProviderError.new("Remote provider endpoints must use HTTPS.", code: "endpoint_forbidden")
      end

      address = enforce_destination!(host, local, trusted_local: trusted_local) if resolve
      [ uri.to_s.sub(%r{/+\z}, ""), address ]
    rescue URI::InvalidURIError
      raise ProviderError.new("Enter a valid provider base URL.", code: "endpoint_invalid")
    rescue ArgumentError
      raise ProviderError.new("Enter a valid provider base URL.", code: "endpoint_invalid")
    end

    def enforce_destination!(host, local, trusted_local: false)
      docker_gateway = trusted_local && docker_host?(host)
      blocked = BLOCKED_HOST_SUFFIXES.any? { |suffix| host.end_with?(suffix) }
      if blocked && !(local && loopback?(host)) && !docker_gateway
        raise ProviderError.new("This provider endpoint is not permitted.", code: "endpoint_forbidden")
      end

      addresses = if loopback?(host)
                    [ IPAddr.new(host == "localhost" || host == "localhost.localdomain" ? "127.0.0.1" : host) ]
      else
                    begin
                      Timeout.timeout(DNS_TIMEOUT) { Resolv.getaddresses(host) }.map { |address| IPAddr.new(address) }
                    rescue ArgumentError, IPAddr::InvalidAddressError, Resolv::ResolvError, SocketError, Timeout::Error
                      raise ProviderError.new("The provider endpoint could not be resolved.", code: "endpoint_invalid")
                    end
      end
      raise ProviderError.new("The provider endpoint could not be resolved.", code: "endpoint_invalid") if addresses.empty?

      blocked_addresses = addresses.select { |address| forbidden_address?(address) }
      trusted_addresses = blocked_addresses.all? { |address| address.loopback? || docker_gateway }
      if blocked_addresses.any? && !(trusted_local && trusted_addresses) &&
          !(!Rails.env.production? && local && blocked_addresses.all?(&:loopback?))
        raise ProviderError.new("This provider endpoint resolves to a prohibited network address.", code: "endpoint_forbidden")
      end

      addresses.first.to_s
    end

    def docker_host?(host)
      host.delete_suffix(".") == "host.docker.internal"
    end

    def forbidden_address?(address)
      address = address.ipv4_mapped if address.ipv4_mapped?
      if address.ipv6? && NAT64_PREFIX.include?(address)
        embedded = IPAddr.new_ntoh([ address.to_i & 0xffff_ffff ].pack("N"))
        return forbidden_address?(embedded)
      end

      BLOCKED_NETWORKS.any? { |network| network.include?(address) }
    end

    def loopback?(host)
      LOOPBACK_HOSTS.include?(host) || IPAddr.new(host).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
