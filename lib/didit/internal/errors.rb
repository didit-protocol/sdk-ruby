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

      # The response of a call whose answer may echo secrets (the agent consent calls), sanitized once on
      # receipt: status kept; each header whose name contains a secret dropped and the other values redacted;
      # the body redacted structurally, never from its raw text (the parsed JSON with every string that
      # contains a secret replaced whole, "[redacted]" when it is not JSON, cut at the size limit or empty).
      # Every error of these calls is built from this response only.
      #
      # @return [Didit::Internal::Transport::Response]
      def sanitized_response(response, secrets)
        # @type var headers: Hash[String, String]
        headers = {}
        response.headers.each do |name, value|
          # Header names are case-insensitive: compare case-folded.
          next if secrets.any? { |secret| secret && !secret.empty? && name.downcase.include?(secret.downcase) }

          headers[name] = Util.redact_structured(value, secrets)
        end
        Transport::Response.new(status: response.status, headers: headers,
                                body: sanitized_body(response.body.to_s, secrets))
      end

      # @return [String] the redacted JSON text, or "[redacted]"
      def sanitized_body(raw_body, secrets)
        return Util::REDACTED if raw_body.empty?

        text = raw_body.dup.force_encoding(Encoding::UTF_8)
        text = text.scrub unless text.valid_encoding?
        JSON.generate(Util.redact_structured(JSON.parse(text), secrets))
      rescue JSON::ParserError, SystemStackError
        # Not JSON, or nested past the parser's or the walk's depth limit: not JSON.
        Util::REDACTED
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
