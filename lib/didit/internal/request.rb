# frozen_string_literal: true

require "date"
require "json"
require "time"
require "uri"

module Didit
  module Internal
    # Builds requests and sends them with the retry policy of docs/DESIGN.md section 7.
    # @api private
    module Request
      # A request with everything resolved.
      Prepared = Struct.new(:http_method, :uri, :headers, :body, :timeout, :max_retries, :origin, :redact,
                            keyword_init: true)
      # A response plus how it was obtained.
      Result = Struct.new(:response, :retries_taken, :elapsed, keyword_init: true)

      IDEMPOTENT = %i[get head put delete options].freeze
      INITIAL_RETRY_DELAY = 0.5
      MAX_RETRY_DELAY = 8.0
      MAX_RETRY_AFTER = 60.0
      OPTION_KEYS = %i[timeout max_retries extra_headers extra_query extra_body].freeze
      UNRESERVED = /[^A-Za-z0-9\-._~]/

      module_function

      # Per-request options (+request_options:+ of every method) merged over the client's.
      def options(config, raw)
        raw ||= {} # : Hash[untyped, untyped]
        raise ConfigurationError, "request_options must be a Hash, got #{raw.class}." unless raw.is_a?(Hash)

        unknown = raw.keys.map(&:to_sym) - OPTION_KEYS
        unless unknown.empty?
          raise ConfigurationError, "Unknown request_options #{unknown.map(&:inspect).join(", ")}; " \
                                    "use #{OPTION_KEYS.map(&:inspect).join(", ")}."
        end
        opts = raw.transform_keys(&:to_sym)
        {
          timeout: Config.check_timeout(opts.fetch(:timeout, config.timeout)),
          max_retries: Config.check_max_retries(opts.fetch(:max_retries, config.max_retries)),
          extra_headers: opts[:extra_headers] || {},
          extra_query: opts[:extra_query] || {},
          extra_body: opts[:extra_body] || {}
        }
      end

      # @return [Prepared]
      def prepare(config, http_method, path, opts, path_params: {}, query: nil, body: nil, encoding: :json,
                  file_fields: [], headers: {}, auth: :api_key, api: :verification, scope: nil,
                  accept: "application/json")
        params = scope == :application ? scoped(config, path_params) : path_params
        check_credentials(config, auth)
        base = api == :account ? config.account_base_url : config.base_url
        uri = URI("#{base}#{encode_path(path, params)}")
        query_string = encode_query(merge(query, opts[:extra_query]))
        uri.query = query_string unless query_string.empty?
        body_bytes, content_type = encode_body(body, opts[:extra_body], encoding, file_fields)
        Prepared.new(
          http_method: http_method, uri: uri, origin: Util.origin(base),
          headers: build_headers(config, auth, accept: accept, content_type: content_type, op_headers: headers,
                                                 extra_headers: opts[:extra_headers]),
          body: body_bytes, timeout: opts[:timeout], max_retries: opts[:max_retries],
          redact: [config.api_key, config.account_token].compact
        )
      end

      # The path parameters plus the organization and application ids of an application-scoped method.
      def scoped(config, path_params)
        organization_id = config.organization_id
        application_id = config.application_id
        unless organization_id && application_id
          raise ConfigurationError,
                "This method is application scoped: pass organization_id and application_id to " \
                "Didit::Client.new (or set DIDIT_ORGANIZATION_ID and DIDIT_APPLICATION_ID)."
        end

        path_params.merge("organization_id" => organization_id, "application_id" => application_id)
      end

      def check_credentials(config, auth)
        case auth
        when :api_key
          return if config.api_key

          raise ConfigurationError,
                "No API key: pass api_key: to Didit::Client.new or set the DIDIT_API_KEY environment variable."
        when :account_token
          return if config.account_token

          raise ConfigurationError,
                "This account method needs an account token: call didit.account.login(...) and pass its " \
                "access_token as account_token: (didit.with_options(account_token: ...))."
        end
      end

      # Fills +{name}+ placeholders with percent-encoded single path segments.
      def encode_path(path, params)
        path.gsub(/\{([^}]+)\}/) do
          name = Regexp.last_match(1).to_s
          value = params.fetch(name) { raise ConfigurationError, "Missing path parameter #{name}." }
          segment = path_segment(name, value)
          segment.b.gsub(UNRESERVED) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::US_ASCII)
        end
      end

      def path_segment(name, value)
        unless value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Symbol)
          raise ConfigurationError, "Path parameter #{name} must be a String, got #{value.class}."
        end

        text = value.to_s
        raise ConfigurationError, "Path parameter #{name} must not be empty." if text.empty?
        raise ConfigurationError, "Path parameter #{name} must not be \".\" or \"..\"." if %w[. ..].include?(text)

        text.encode(Encoding::UTF_8)
      end

      def merge(values, extra)
        # @type var out: Hash[String, untyped]
        out = {}
        (values || {}).each { |k, v| out[k.to_s] = v unless v.equal?(OMIT) }
        (extra || {}).each { |k, v| out[k.to_s] = v }
        out
      end

      # Query values: nil and omitted values are left out, arrays repeat the key.
      def encode_query(values)
        # @type var pairs: Array[[String, String]]
        pairs = []
        values.each do |key, value|
          Array(value.is_a?(Hash) ? JSON.generate(json_value(value)) : value).each do |item|
            pairs << [key, query_value(item)] unless item.nil? || item.equal?(OMIT)
          end
        end
        URI.encode_www_form(pairs)
      end

      def query_value(value)
        case value
        when Time then value.utc.iso8601(6)
        when Date then value.iso8601
        else value.to_s
        end
      end

      # @return [Array(String, String), Array(nil, nil)] body bytes and content type
      def encode_body(body, extra_body, encoding, file_fields)
        return [nil, nil] if body.nil? && (extra_body.nil? || extra_body.empty?)

        fields = merge(body, extra_body)
        multipart = encoding == :multipart ||
                    (encoding == :auto && file_fields.any? { |f| !fields[f].nil? })
        if multipart
          Multipart.encode(fields, file_fields)
        else
          [JSON.generate(json_value(fields)), "application/json"]
        end
      end

      # A value ready for JSON: string keys, Time and Date as ISO 8601.
      def json_value(value)
        case value
        when Hash
          # @type var out: Hash[String, untyped]
          out = {}
          value.each { |k, v| out[k.to_s] = json_value(v) unless v.equal?(OMIT) }
          out
        when Array then value.map { |v| json_value(v) }
        when Time then value.utc.iso8601(6)
        when Date then value.iso8601
        when Symbol then value.to_s
        when Didit::Model then json_value(value.to_h)
        when FilePart
          raise ConfigurationError, "A file can only be sent to an operation that accepts uploads."
        else value
        end
      end

      def build_headers(config, auth, accept:, content_type:, op_headers:, extra_headers:)
        # @type var headers: Hash[String, String]
        headers = {}
        put = lambda do |name, value|
          headers.delete_if { |k, _| k.casecmp?(name) }
          headers[name] = value.to_s unless value.nil?
        end
        put.call("Accept", accept)
        put.call("User-Agent", Util.user_agent)
        put.call("X-Didit-Client", Util.client_header)
        config.default_headers.each { |name, value| put.call(name.to_s, value) }
        credential = credential_header(config, auth)
        put.call(*credential) if credential
        put.call("Content-Type", content_type) if content_type
        op_headers.each { |name, value| put.call(name, value) unless value.equal?(OMIT) }
        extra_headers.each { |name, value| put.call(name.to_s, value) }
        headers
      end

      # The credential header for +auth+, sent only to the origin the request was built for.
      def credential_header(config, auth)
        case auth
        when :api_key then ["x-api-key", config.api_key.to_s]
        when :account_token then ["Authorization", "Bearer #{config.account_token}"]
        end
      end

      # One try: the response, or the failure and whether any body chunk was already streamed.
      Attempt = Struct.new(:response, :failure, :streamed, :elapsed, keyword_init: true)

      # Sends +prepared+, retrying as docs/DESIGN.md section 7 says.
      #
      # @return [Result]
      def perform(config, transport, prepared, &block)
        retries = 0
        loop do
          attempt = attempt(transport, prepared, &block)
          delay = retry_delay(config, prepared, attempt, retries)
          if delay.nil?
            failure = attempt.failure
            raise connection_error(prepared, failure), cause: failure if failure

            return Result.new(response: attempt.response, retries_taken: retries, elapsed: attempt.elapsed)
          end
          retries += 1
          Util.pause(delay)
        end
      end

      def attempt(transport, prepared)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = Attempt.new(streamed: false)
        # @type var stream: (^(String) -> void)?
        stream = nil
        if block_given?
          stream = lambda do |chunk|
            result.streamed = true
            yield(chunk)
          end
        end
        begin
          result.response = transport.execute(prepared.http_method, prepared.uri, prepared.headers, prepared.body,
                                              prepared.timeout, &stream)
        rescue Transport::Failure => e
          result.failure = e
        end
        result.elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        result
      end

      # Seconds to wait before the next try, or nil when this attempt is final.
      def retry_delay(config, prepared, attempt, retries)
        left = prepared.max_retries - retries
        if (failure = attempt.failure)
          return nil if attempt.streamed || left <= 0 || !retry_failure?(prepared.http_method, failure)

          delay = backoff(retries)
          Log.retry(config, prepared, failure.timeout? ? "timed out" : failure.error.class.name, delay, left)
          return delay
        end
        response = attempt.response
        Log.response(config, prepared, response, attempt.elapsed)
        return nil if left <= 0 || !retry_status?(prepared.http_method, response.status)

        delay = retry_after(response.headers["retry-after"]) || backoff(retries)
        Log.retry(config, prepared, "HTTP #{response.status}", delay, left)
        delay
      end

      def retry_status?(http_method, status)
        return true if status == 429
        return false unless IDEMPOTENT.include?(http_method)

        status == 408 || status.between?(500, 599)
      end

      def retry_failure?(http_method, failure)
        !failure.sent || IDEMPOTENT.include?(http_method)
      end

      # Exponential backoff from 0.5 s with full jitter, capped at 8 s.
      def backoff(retries_taken)
        Kernel.rand * [MAX_RETRY_DELAY, INITIAL_RETRY_DELAY * (2**retries_taken)].min
      end

      # Seconds to wait from a Retry-After header (seconds or HTTP date), capped at 60.
      def retry_after(value, now: Time.now)
        return nil if value.nil?

        text = value.strip
        seconds = text.match?(/\A\d+(\.\d+)?\z/) ? text.to_f : http_date_seconds(text, now)
        seconds&.clamp(0.0, MAX_RETRY_AFTER)
      end

      def http_date_seconds(text, now)
        Time.httpdate(text) - now
      rescue ArgumentError
        nil
      end

      def connection_error(prepared, failure)
        url = Util.display_url(prepared.uri)
        method = prepared.http_method.to_s.upcase
        if failure.timeout?
          APITimeoutError.new("Request timed out (#{method} #{url}).", http_method: method, url: url)
        else
          detail = Util.redact(failure.error.message.to_s, prepared.redact)
          APIConnectionError.new("Connection error (#{method} #{url}): #{failure.error.class}: #{detail}",
                                 http_method: method, url: url)
        end
      end
    end
  end
end
