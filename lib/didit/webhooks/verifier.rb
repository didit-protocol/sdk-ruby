# frozen_string_literal: true

require "json"
require "openssl"

module Didit
  module Webhooks
    # One verification (docs/DESIGN.md section 9.3). {Didit::Webhooks.verify} and
    # {Didit::Webhooks.verify_parsed} are the public entry points.
    #
    # @api private
    class Verifier
      # Signatures over the whole body, in the order they are tried for each secret.
      FULL_BODY = [
        HEADER_SIGNATURE, HEADER_SIGNATURE_V2, HEADER_SIGNATURE_PREVIOUS, HEADER_SIGNATURE_V2_PREVIOUS
      ].freeze
      # Signatures of the canonical JSON, the only ones a parsed body can be checked against.
      CANONICAL = [HEADER_SIGNATURE_V2, HEADER_SIGNATURE_V2_PREVIOUS].freeze
      # The deprecated envelope-only signatures.
      SIMPLE = [HEADER_SIGNATURE_SIMPLE, HEADER_SIGNATURE_SIMPLE_PREVIOUS].freeze
      ALL = (FULL_BODY + SIMPLE).freeze
      # The fields X-Signature-Simple signs, in order.
      SIMPLE_FIELDS = %w[timestamp session_id status webhook_type].freeze

      # Timestamps at or beyond this many seconds from 1970 (16 digits) are never in tolerance.
      MAX_TIMESTAMP = 1_000_000_000_000_000
      # X-Timestamp: an optional sign and digits (leading zeros allowed), at most 32 characters.
      TIMESTAMP_HEADER = /\A[+-]?[0-9]{1,31}\z/
      # Strict JSON (no NaN). A repeated key keeps its last value, like Python. json 2.13 added
      # allow_duplicate_key for that (without it json 2.13+ warns and json 3 raises); older
      # versions do not know the option and keep the last value anyway.
      DUPLICATE_KEY_OPTION = (JSON::VERSION.split(".").map(&:to_i) <=> [2, 13]).to_i >= 0
      PARSE_OPTIONS = (DUPLICATE_KEY_OPTION ? { allow_nan: false, allow_duplicate_key: true } : { allow_nan: false })
                      .freeze

      # @raise [Didit::ConfigurationError] for a missing or empty secret, a bad tolerance or clock,
      #   or headers that cannot be read
      def initialize(secret, headers, tolerance:, now:)
        @keys = secret_keys(secret)
        @tolerance = check_tolerance(tolerance)
        @now = check_now(now)
        @headers = Headers.new(headers)
        @raw = nil
        @payload = nil
        @digests = {}
      end

      # @return [Event]
      def verify(raw_body, allow_simple:)
        # Only true turns the envelope-only signature on: "false" from an environment variable must not.
        unless [true, false].include?(allow_simple)
          raise ConfigurationError, "allow_simple must be true or false, got #{allow_simple.inspect}."
        end

        raw = body_bytes(raw_body)
        @raw = raw
        @payload = normalize(parse_json(raw))
        verified_by = check_signatures(allow_simple ? FULL_BODY + SIMPLE : FULL_BODY)
        Event.build(payload, verified_by)
      end

      # @return [Event]
      def verify_parsed(payload)
        unless payload.is_a?(Hash)
          raise failure(:invalid_payload,
                        "verify_parsed needs the parsed JSON object (a Hash), not a #{payload.class}; " \
                        "pass the raw body String to verify instead.")
        end

        @payload = normalize(payload)
        Event.build(self.payload, check_signatures(CANONICAL))
      end

      private

      # The parsed body, a Hash with String keys.
      def payload
        @payload || raise(ArgumentError, "no payload")
      end

      def secret_keys(secret)
        if secret.nil?
          raise ConfigurationError, "No webhook secret (nil); copy it from the webhook destination in the " \
                                    "Didit console, for example into DIDIT_WEBHOOK_SECRET."
        end
        list = secret.is_a?(Array) ? secret : [secret]
        raise ConfigurationError, "No webhook secret (an empty list)." if list.empty?

        list.map { |item| key_bytes(item) }
      end

      def key_bytes(secret)
        unless secret.is_a?(String)
          raise ConfigurationError, "The webhook secret must be a String or an Array of Strings."
        end
        raise ConfigurationError, "The webhook secret is empty." if secret.empty?

        (secret.encoding == Encoding::BINARY ? secret : secret.encode(Encoding::UTF_8)).b
      rescue EncodingError
        raise ConfigurationError, "The webhook secret cannot be converted to UTF-8."
      end

      def check_tolerance(tolerance)
        number = tolerance.is_a?(Integer) || tolerance.is_a?(Float)
        # `>= 0` is false for NaN, which would otherwise switch the replay check off.
        return tolerance if number && tolerance >= 0

        raise ConfigurationError, "tolerance must be a number of seconds, 0 or more."
      end

      def check_now(now)
        return Time.now.to_f if now.nil?
        return now if now.is_a?(Integer) || (now.is_a?(Float) && now.finite?)

        raise ConfigurationError, "now must be unix seconds, an Integer or a Float."
      end

      def body_bytes(raw_body)
        return raw_body.b if raw_body.is_a?(String)

        raise failure(:invalid_payload, "The webhook body must be the raw request body as a String, " \
                                        "not a #{raw_body.class}.")
      end

      # Every parser failure is invalid_payload, whatever the JSON library raises.
      def parse_json(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        raise failure(:invalid_payload, "The webhook body is not valid UTF-8.") unless text.valid_encoding?

        value = begin
          JSON.parse(text, **PARSE_OPTIONS)
        rescue StandardError # JSON::ParserError, JSON::NestingError, EncodingError, ...
          raise failure(:invalid_payload, "The webhook body is not valid JSON.")
        end
        raise failure(:invalid_payload, "The webhook body is not a JSON object.") unless value.is_a?(Hash)

        value
      end

      def normalize(value)
        CanonicalJson.normalize(value)
      rescue ArgumentError => e
        raise failure(:invalid_payload, "The webhook payload is not JSON data Didit sends: #{e.message}.")
      end

      # Steps 3 to 9 of the rules: timestamp, then the signatures in order.
      def check_signatures(checked)
        check_timestamp
        unless ALL.any? { |name| @headers.present?(name) }
          raise failure(:missing_signature,
                        "The request has no Didit signature header (X-Signature, X-Signature-V2 or " \
                        "X-Signature-Simple).")
        end

        match(checked) || raise(no_match(checked))
      end

      def check_timestamp
        timestamp = payload["timestamp"]
        unless timestamp.is_a?(Integer)
          raise failure(:missing_timestamp, "The webhook body has no integer \"timestamp\".")
        end

        stale = timestamp >= MAX_TIMESTAMP || timestamp <= -MAX_TIMESTAMP
        check_timestamp_header(timestamp) unless stale
        return unless stale || (@now - timestamp).abs > @tolerance

        raise failure(:timestamp_out_of_tolerance,
                      "The webhook timestamp is more than #{@tolerance} seconds away from now: a delayed or " \
                      "replayed delivery, or a clock that is off.")
      end

      def check_timestamp_header(timestamp)
        header = @headers.timestamp
        return if header.nil? || (header.match?(TIMESTAMP_HEADER) && Integer(header, 10) == timestamp)

        raise failure(:timestamp_mismatch, "X-Timestamp does not match the \"timestamp\" in the webhook body.")
      end

      # The first header, for the first secret, whose signature matches; nil when none does.
      def match(checked)
        full = checked & FULL_BODY
        simple = checked & SIMPLE
        @keys.each do |key|
          full.each { |name| return name if signed?(key, name) }
        end
        return if simple.empty? || simple_message.nil?

        @keys.each do |key|
          simple.each { |name| return name if signed?(key, name) }
        end
        nil
      end

      def signed?(key, name)
        candidates = @headers.signatures(name)
        return false if candidates.empty?

        expected = digest(key, name)
        candidates.any? { |candidate| OpenSSL.fixed_length_secure_compare(expected, candidate) }
      end

      # The HMAC of what +name+ signs; a header and its -Previous variant share it.
      def digest(key, name)
        kind = message_kind(name)
        @digests[[key, kind]] ||= OpenSSL::HMAC.hexdigest("SHA256", key, message(kind))
      end

      def message_kind(name)
        return :canonical if CANONICAL.include?(name)

        SIMPLE.include?(name) ? :simple : :raw
      end

      def message(kind)
        case kind
        when :raw then @raw || raise(ArgumentError, "no raw body")
        when :canonical then canonical
        else simple_message || raise(ArgumentError, "no simple message")
        end
      end

      # Built only when an X-Signature-V2 value is well formed and nothing matched before it.
      def canonical
        @canonical ||= CanonicalJson.dump(payload)
      end

      # "{timestamp}:{session_id}:{status}:{webhook_type}" with Python's str() of each value;
      # nil when one of them is an object or an array, which never matches.
      def simple_message
        return @simple_message if defined?(@simple_message)

        parts = SIMPLE_FIELDS.map { |field| payload.key?(field) ? CanonicalJson.python_str(payload[field]) : "" }
        @simple_message = parts.all? ? parts.join(":") : nil
      end

      def no_match(checked)
        present = ALL.select { |name| @headers.present?(name) }
        message =
          if checked == CANONICAL && !present.intersect?(CANONICAL)
            "verify_parsed can check only X-Signature-V2, and the request has none; pass the raw body to verify."
          elsif checked == CANONICAL
            "X-Signature-V2 does not match: check that the secret belongs to this destination and that the " \
              "payload is the body as parsed, unchanged."
          elsif !present.intersect?(checked)
            "The request carries only X-Signature-Simple, which does not cover the body and counts only " \
              "with allow_simple: true."
          else
            "No webhook signature matches the secret: check that the secret belongs to this destination and " \
              "that the raw body reaches verify unchanged."
          end
        failure(:invalid_signature, message)
      end

      def failure(reason, message)
        WebhookVerificationError.new(reason, message)
      end
    end
  end
end
