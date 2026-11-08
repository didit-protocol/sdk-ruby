# frozen_string_literal: true

module Didit
  # The HTTP response behind a result, from +didit.with_raw_response+:
  #
  #   raw = didit.with_raw_response.sessions.create(workflow_id: "...")
  #   raw.status      # => 201
  #   raw.request_id  # => "..."
  #   session = raw.parse
  class RawResponse
    # @return [Integer]
    attr_reader :status
    # @return [Hash{String => String}] header names in lower case
    attr_reader :headers
    # @return [String, nil] the body bytes (nil when a block received them)
    attr_reader :body
    # @return [Integer] how many retries it took
    attr_reader :retries_taken
    # @return [Float] seconds the last attempt took
    attr_reader :elapsed

    # @api private
    def initialize(status:, headers:, body:, retries_taken:, elapsed:, parser:)
      @status = status
      @headers = headers
      @body = body
      @retries_taken = retries_taken
      @elapsed = elapsed
      @parser = parser
      @parsed = false
      @value = nil
    end

    # @return [Integer] alias of {#status}
    def status_code
      status
    end

    # @return [String, nil]
    def request_id
      Internal::Util.request_id(headers)
    end

    # The typed result the method returns without +with_raw_response+.
    def parse
      unless @parsed
        @value = @parser.call
        @parsed = true
      end
      @value
    end

    def inspect
      "#<Didit::RawResponse status=#{status} request_id=#{request_id.inspect}>"
    end
  end
end
