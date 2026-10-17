# frozen_string_literal: true

require "json"
require "uri"

module Didit
  class Authentication
    # Requests to the issuer over the SDK's transport ({Didit::Internal::Transport}):
    # never retried, redirects never followed, the API key never sent.
    # @api private
    class Http
      # One request to the issuer.
      class Call
        # @return [String] "GET", "POST" or "DELETE"
        attr_reader :http_method
        # @return [URI::Generic]
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

        # "GET /session/", for messages.
        def describe
          "#{http_method} #{uri.path}"
        end
      end

      VERBS = { "GET" => :get, "POST" => :post, "DELETE" => :delete }.freeze

      # @param timeout [Numeric] seconds for opening the connection, and for each read and write
      # @param http_client [#call, nil] returns a configured, not yet started Net::HTTP for a URI
      def initialize(timeout:, http_client:)
        @timeout = timeout.to_f
        @transport = Internal::Transport.new(http_client: http_client)
        freeze
      end

      # Sends +call+ once and returns the response, whatever its status.
      #
      # @param call [Call]
      # @return [Didit::Internal::Transport::Response]
      # @raise [Didit::APIConnectionError, Didit::APITimeoutError] when no response arrives
      def perform(call)
        @transport.execute(VERBS.fetch(call.http_method), call.uri, headers_for(call), body_for(call), @timeout)
      rescue Internal::Transport::Failure => e
        error_class = e.timeout? ? APITimeoutError : APIConnectionError
        raise error_class.new(http_method: call.http_method, url: call.display_url)
      end

      # The parsed JSON body of a 2xx response, nil when it has none.
      #
      # @return [Object, nil]
      # @raise [Didit::APIStatusError] for any other status, with the call's secrets redacted
      # @raise [Didit::APIResponseValidationError] when the body is not JSON
      def read(call, response)
        body = response.body.to_s
        unless (200..299).cover?(response.status)
          raise Internal::Errors.status_error(
            status: response.status, headers: response.headers, raw_body: body, redact: call.secrets
          )
        end
        return nil if response.status == 204 || body.empty?

        begin
          JSON.parse(text_of(body))
        rescue JSON::ParserError
          content_type = response.headers.fetch("content-type", "no content type")
          raise validation_error(call, response, "Expected a JSON response from #{call.describe}, got #{content_type}.")
        end
      end

      # The JSON object of a 2xx response.
      #
      # @return [Hash]
      def read_object(call, response)
        data = read(call, response)
        raise validation_error(call, response, "Expected a JSON object from #{call.describe}.") unless data.is_a?(Hash)

        data
      end

      # @return [Didit::APIResponseValidationError]
      def validation_error(call, response, message)
        body = response.body.to_s
        APIResponseValidationError.new(
          message, status: response.status, headers: response.headers,
                   body: body.empty? ? nil : Internal::Util.redact(text_of(body), call.secrets),
                   request_id: Internal::Util.request_id(response.headers)
        )
      end

      private

      def headers_for(call)
        headers = {
          "Accept" => "application/json",
          "User-Agent" => Internal::Util.user_agent,
          "X-Didit-Client" => Internal::Util.client_header
        }
        headers["Authorization"] = "Bearer #{call.bearer}" if call.bearer
        if call.form
          headers["Content-Type"] = "application/x-www-form-urlencoded"
        elsif call.json
          headers["Content-Type"] = "application/json"
        end
        headers
      end

      def body_for(call)
        form = call.form
        json = call.json
        return URI.encode_www_form(form) if form

        JSON.generate(json) if json
      end

      def text_of(body)
        text = body.dup.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : text.scrub
      end
    end
  end
end
