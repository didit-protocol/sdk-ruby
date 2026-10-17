# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Didit
  class Authentication
    # Sends requests to the issuer with +Net::HTTP+: one connection per request,
    # no retries, no redirects followed.
    # @api private
    class Transport
      # One request to the issuer.
      class Call
        # @return [String] "GET", "POST" or "DELETE"
        attr_reader :http_method
        # @return [URI::HTTP]
        attr_reader :uri
        # @return [String, nil] sent as +Authorization: Bearer+
        attr_reader :bearer
        # @return [Hash{String => String}, nil] form-encoded body
        attr_reader :form
        # @return [Hash{String => Object}, nil] JSON body
        attr_reader :json
        # @return [Array<String>] tokens, codes and verifiers redacted from errors
        attr_reader :secrets

        def initialize(http_method, uri, bearer: nil, form: nil, json: nil, secrets: [])
          @http_method = http_method
          @uri = uri
          @bearer = bearer
          @form = form
          @json = json
          @secrets = secrets
          freeze
        end

        # The URL without query string or credentials, for errors.
        def display_url
          Internal::Util.display_url(uri)
        end
      end

      # A response: the status, the headers (names in lower case) and the body.
      class Response
        attr_reader :status, :headers, :body

        def initialize(status, headers, body)
          @status = status
          @headers = headers
          @body = body
          freeze
        end

        def success?
          (200..299).cover?(status)
        end
      end

      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError,
        Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
      ].freeze
      REQUESTS = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "DELETE" => Net::HTTP::Delete }.freeze

      # @param timeout [Numeric] seconds for opening the connection, and for each read and write
      # @param http_client [#call, nil] returns a configured, not yet started Net::HTTP for a URI
      def initialize(timeout:, http_client:)
        @timeout = timeout
        @http_client = http_client
        freeze
      end

      # Sends +call+ and returns the response, whatever its status.
      #
      # @param call [Call]
      # @return [Response]
      # @raise [Didit::APIConnectionError, Didit::APITimeoutError] when no response arrives
      def perform(call)
        http = connection(call.uri)
        response = http.start { |conn| conn.request(request_for(call)) }
        Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
      rescue Timeout::Error, Errno::ETIMEDOUT
        raise APITimeoutError.new(http_method: call.http_method, url: call.display_url)
      rescue *CONNECTION_ERRORS
        raise APIConnectionError.new(http_method: call.http_method, url: call.display_url)
      end

      # The parsed JSON body of a 2xx response, nil when it has none.
      #
      # @return [Object, nil]
      # @raise [Didit::APIStatusError] for any other status, with the call's secrets redacted
      # @raise [Didit::APIResponseValidationError] when the body is not JSON
      def read(call, response)
        unless response.success?
          raise Internal::Errors.status_error(
            status: response.status, headers: response.headers, raw_body: response.body, redact: call.secrets
          )
        end
        return nil if response.status == 204 || response.body.empty?

        JSON.parse(text_of(response))
      rescue JSON::ParserError
        content_type = response.headers.fetch("content-type", "no content type")
        raise validation_error(call, response, "Expected a JSON response from #{describe(call)}, got #{content_type}.")
      end

      # The JSON object of a 2xx response.
      #
      # @return [Hash]
      def read_object(call, response)
        data = read(call, response)
        raise validation_error(call, response, "Expected a JSON object from #{describe(call)}.") unless data.is_a?(Hash)

        data
      end

      # @return [Didit::APIResponseValidationError]
      def validation_error(call, response, message)
        body = response.body.empty? ? nil : Internal::Util.redact(text_of(response), call.secrets)
        APIResponseValidationError.new(
          message, status: response.status, headers: response.headers, body: body,
                   request_id: Internal::Util.request_id(response.headers)
        )
      end

      private

      def describe(call)
        "#{call.http_method} #{call.uri.path}"
      end

      def text_of(response)
        text = response.body.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub
      end

      def connection(uri)
        http = @http_client ? @http_client.call(uri) : default_connection(uri)
        unless http.is_a?(Net::HTTP)
          raise ConfigurationError, "http_client must return a Net::HTTP for the URI it is given, got #{http.class}."
        end

        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout
        # Net::HTTP retries idempotent requests once by default; the issuer's never are.
        http.max_retries = 0
        http
      end

      def default_connection(uri)
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = uri.scheme == "https"
        http
      end

      def request_for(call)
        request = REQUESTS.fetch(call.http_method).new(call.uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = Internal::Util.user_agent
        request["X-Didit-Client"] = Internal::Util.client_header
        request["Authorization"] = "Bearer #{call.bearer}" if call.bearer
        if call.form
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.body = URI.encode_www_form(call.form)
        elsif call.json
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(call.json)
        end
        request
      end
    end
  end
end
