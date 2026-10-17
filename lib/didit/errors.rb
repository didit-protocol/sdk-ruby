# frozen_string_literal: true

module Didit
  # Base class of every error the SDK raises (docs/DESIGN.md section 7).
  class DiditError < StandardError
  end

  # The client is missing something it needs (an API key, an account token, the
  # organization or application id, a webhook secret) or an argument is invalid.
  # Raised before any request is sent.
  class ConfigurationError < DiditError
  end

  # No response arrived: the connection failed or broke.
  class APIConnectionError < DiditError
    # @return [String, nil] the HTTP method of the request
    attr_reader :http_method
    # @return [String, nil] the request URL without its query string
    attr_reader :url

    def initialize(message = "Connection error.", http_method: nil, url: nil)
      super(message)
      @http_method = http_method
      @url = url
    end
  end

  # The request timed out before a response arrived.
  class APITimeoutError < APIConnectionError
    def initialize(message = "Request timed out.", http_method: nil, url: nil)
      super
    end
  end

  # Shared readers of the errors that carry an HTTP response.
  module ResponseDetails
    # @return [Integer] the HTTP status code
    attr_reader :status
    # @return [Hash{String => String}] response headers, names in lower case
    attr_reader :headers
    # @return [Object, nil] the parsed JSON body, else the text, else nil
    attr_reader :body
    # @return [String, nil] the request id the API returned, if any
    attr_reader :request_id

    # @return [Integer] alias of {#status}
    def status_code
      status
    end
  end

  # A successful response could not be read as the documented content (for
  # example HTML where JSON was expected, or a pagination link that loops).
  class APIResponseValidationError < DiditError
    include ResponseDetails

    def initialize(message, status:, headers: {}, body: nil, request_id: nil)
      super(message)
      @status = status
      @headers = headers
      @body = body
      @request_id = request_id
    end
  end

  # The API answered with a non-2xx status.
  class APIStatusError < DiditError
    include ResponseDetails

    def initialize(message, status:, headers: {}, body: nil, request_id: nil)
      super(request_id ? "#{message} (request id #{request_id})" : message)
      @status = status
      @headers = headers
      @body = body
      @request_id = request_id
    end
  end

  # HTTP 400.
  class BadRequestError < APIStatusError
  end

  # HTTP 401.
  class AuthenticationError < APIStatusError
  end

  # HTTP 403.
  class PermissionDeniedError < APIStatusError
  end

  # HTTP 404.
  class NotFoundError < APIStatusError
  end

  # HTTP 409.
  class ConflictError < APIStatusError
  end

  # HTTP 422.
  class UnprocessableEntityError < APIStatusError
  end

  # HTTP 429.
  class RateLimitError < APIStatusError
  end

  # HTTP 5xx.
  class InternalServerError < APIStatusError
  end

  # A webhook delivery failed verification (docs/DESIGN.md section 9.3).
  #
  # {#reason} is machine readable: +:missing_signature+, +:invalid_signature+,
  # +:missing_timestamp+, +:timestamp_mismatch+, +:timestamp_out_of_tolerance+
  # or +:invalid_payload+.
  class WebhookVerificationError < DiditError
    REASONS = %i[
      missing_signature invalid_signature missing_timestamp
      timestamp_mismatch timestamp_out_of_tolerance invalid_payload
    ].freeze

    # @return [Symbol]
    attr_reader :reason

    def initialize(reason, message)
      super(message)
      @reason = reason
    end
  end

  # An Authentication access token or ID token failed verification: do not trust
  # any of its claims (docs/DESIGN.md section 10). The message never contains the token.
  #
  # {#reason} is machine readable: +:malformed+, +:unsupported_algorithm+,
  # +:invalid_type+, +:unknown_key+, +:invalid_signature+, +:invalid_issuer+,
  # +:invalid_audience+, +:expired+, +:not_yet_valid+, +:invalid_issued_at+,
  # +:invalid_nonce+ or +:missing_claim+.
  class TokenVerificationError < DiditError
    REASONS = %i[
      malformed unsupported_algorithm invalid_type unknown_key invalid_signature
      invalid_issuer invalid_audience expired not_yet_valid invalid_issued_at
      invalid_nonce missing_claim
    ].freeze

    # @return [Symbol]
    attr_reader :reason

    def initialize(reason, message)
      super(message)
      @reason = reason
    end
  end
end
