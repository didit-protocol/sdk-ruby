# frozen_string_literal: true

require "json"

module Didit
  module Internal
    # Builds {Didit::APIStatusError} subclasses from responses.
    # @api private
    module Errors
      STATUS_ERRORS = {
        400 => BadRequestError,
        401 => AuthenticationError,
        403 => PermissionDeniedError,
        404 => NotFoundError,
        409 => ConflictError,
        422 => UnprocessableEntityError,
        429 => RateLimitError
      }.freeze
      DETAIL_KEYS = %w[detail message error error_description].freeze

      module_function

      # @param status [Integer]
      # @param headers [Hash{String => String}] names in lower case
      # @param raw_body [String, nil]
      # @param redact [Array<String, nil>] secrets to replace with "[redacted]" in the message and body
      # @return [Didit::APIStatusError]
      def status_error(status:, headers:, raw_body:, redact: [])
        body = Util.redact(parse_body(raw_body), redact)
        message = Util.redact(message_for(status, body), redact)
        klass = STATUS_ERRORS.fetch(status) { status >= 500 ? InternalServerError : APIStatusError }
        klass.new(message, status: status, headers: headers, body: body, request_id: Util.request_id(headers))
      end

      # The parsed JSON body, else the text, else nil.
      def parse_body(raw_body)
        return nil if raw_body.nil? || raw_body.empty?

        text = raw_body.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub unless text.valid_encoding?
        JSON.parse(text)
      rescue JSON::ParserError
        text
      end

      def message_for(status, body)
        detail = detail_of(body)
        detail ? "HTTP #{status}: #{detail}" : "HTTP #{status}"
      end

      def detail_of(body)
        case body
        when Hash then hash_detail(body)
        when Array then body.join("; ") if !body.empty? && body.all?(String)
        when String
          text = body.strip
          text unless text.empty? || text.length > 500
        end
      end

      def hash_detail(body)
        error = body["error"]
        description = body["error_description"]
        # OAuth 2.0 errors (RFC 6749 section 5.2): the code and what it means.
        return "#{error}: #{description}" if present?(error) && present?(description)

        DETAIL_KEYS.each { |key| return body[key] if present?(body[key]) }
        parts = body.first(5).filter_map do |key, value|
          if value.is_a?(Array) && value.first.is_a?(String)
            "#{key}: #{value.first}"
          elsif value.is_a?(String)
            "#{key}: #{value}"
          end
        end
        parts.join("; ") unless parts.empty?
      end

      def present?(value)
        value.is_a?(String) && !value.empty?
      end
    end
  end
end
