# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"

module DiditCodegen
  module Sync
    # Downloads one upstream document: https only, a fixed User-Agent, a 60 second
    # timeout, at most 3 redirects on the same host, at most 50 MB.
    class Downloader
      USER_AGENT = "didit-sdk-ruby-spec-sync"
      TIMEOUT = 60
      MAX_REDIRECTS = 3
      MAX_BYTES = 50 * 1024 * 1024
      REDIRECTS = [301, 302, 303, 307, 308].freeze
      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, OpenSSL::SSL::SSLError, IOError,
        SystemCallError, Net::HTTPBadResponse, Zlib::Error
      ].freeze

      def initialize(timeout: TIMEOUT, max_bytes: MAX_BYTES)
        @timeout = timeout
        @max_bytes = max_bytes
      end

      # @return [String] the body, binary
      # @raise [InputError]
      def fetch(url)
        uri = https_uri(url, url)
        host = uri.host.downcase
        (MAX_REDIRECTS + 1).times do
          status, value = get(uri)
          return value if status == :ok

          location = https_uri(value, url, base: uri)
          unless location.host.downcase == host
            raise InputError, "GET #{url}: refusing the redirect to another host (#{location.host})."
          end

          uri = location
        end
        raise InputError, "GET #{url}: more than #{MAX_REDIRECTS} redirects."
      end

      private

      def https_uri(value, url, base: nil)
        uri = base ? base + value.to_s : URI(value.to_s)
        raise InputError, "GET #{url}: only https URLs are allowed, got #{value}." unless uri.is_a?(URI::HTTPS)

        uri
      rescue URI::Error => e
        raise InputError, "GET #{url}: invalid URL #{value.inspect} (#{e.message})."
      end

      # @return [Array(Symbol, String)] [:ok, body] or [:redirect, location]
      def get(uri)
        deadline = monotonic + @timeout
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"] = "application/json"
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @timeout, read_timeout: @timeout,
                                            write_timeout: @timeout, ssl_timeout: @timeout) do |http|
          http.request(request) { |response| return handle(uri, response, deadline) }
        end
      rescue *NETWORK_ERRORS => e
        raise InputError, "GET #{uri}: #{e.class}: #{e.message}"
      end

      def handle(uri, response, deadline)
        code = response.code.to_i
        if REDIRECTS.include?(code)
          location = response["location"]
          raise InputError, "GET #{uri}: HTTP #{code} without a Location header." if location.to_s.empty?

          return [:redirect, location]
        end
        raise InputError, "GET #{uri}: HTTP #{code}." unless code == 200

        [:ok, read(uri, response, deadline)]
      end

      def read(uri, response, deadline)
        length = response["content-length"].to_i
        raise InputError, "GET #{uri}: the document is larger than #{@max_bytes} bytes." if length > @max_bytes

        body = String.new(encoding: Encoding::BINARY)
        response.read_body do |chunk|
          body << chunk.b
          raise InputError, "GET #{uri}: the document is larger than #{@max_bytes} bytes." if body.bytesize > @max_bytes
          raise InputError, "GET #{uri}: timed out after #{@timeout} seconds." if monotonic > deadline
        end
        body
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
