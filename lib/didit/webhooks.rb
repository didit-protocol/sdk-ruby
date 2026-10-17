# frozen_string_literal: true

module Didit
  # Verify Didit webhook deliveries and read them as typed events (docs/DESIGN.md section 9).
  #
  #   event = Didit::Webhooks.verify(request.raw_post, request.headers, ENV.fetch("DIDIT_WEBHOOK_SECRET"))
  #   case event
  #   in Didit::Webhooks::StatusUpdatedEvent(status: "Approved", session_id:) then approve(session_id)
  #   in Didit::Webhooks::UnknownEvent then nil # a type this SDK version does not know yet
  #   else nil
  #   end
  #
  # The verifier needs no client, no API key and no framework; +examples/webhooks/+ has Rails,
  # Sinatra and plain Rack receivers. The same methods are on +client.webhooks+.
  module Webhooks
    # Default maximum distance in seconds between the delivery's timestamp and now.
    DEFAULT_TOLERANCE = 300

    HEADER_SIGNATURE = "X-Signature"
    HEADER_SIGNATURE_V2 = "X-Signature-V2"
    HEADER_SIGNATURE_SIMPLE = "X-Signature-Simple"
    HEADER_SIGNATURE_PREVIOUS = "X-Signature-Previous"
    HEADER_SIGNATURE_V2_PREVIOUS = "X-Signature-V2-Previous"
    HEADER_SIGNATURE_SIMPLE_PREVIOUS = "X-Signature-Simple-Previous"
    HEADER_TIMESTAMP = "X-Timestamp"

    class << self
      # Verifies a webhook delivery and returns its typed event.
      #
      # Pass the exact bytes of the request body (+request.raw_post+, +request.body.read+).
      # The delivery is accepted when, for one of the secrets, +X-Signature+ matches the body,
      # +X-Signature-V2+ matches its canonical JSON (it survives middleware that re-encodes the
      # JSON), or one of their +-Previous+ variants matches (secret rotation). The deprecated
      # +X-Signature-Simple+ counts only with +allow_simple: true+, and then
      # {Event#body_authenticated?} is false: re-fetch the record from the API.
      #
      # @param raw_body [String] the request body as received, in any encoding (read as UTF-8)
      # @param headers [Hash, #each] request headers: a Hash (names in any case), a Rack env,
      #   Rails +request.headers+, or [name, value] pairs
      # @param secret [String, Array<String>] the destination's secret, or several during a rotation
      # @param tolerance [Integer, Float] largest accepted distance in seconds between the
      #   delivery's timestamp and now
      # @param allow_simple [Boolean] also accept the envelope-only +X-Signature-Simple+
      # @param now [Integer, Float, nil] the current unix time, for tests
      # @return [Event]
      # @raise [Didit::WebhookVerificationError] when the delivery fails verification; +reason+ says why
      # @raise [Didit::ConfigurationError] for a missing or empty secret, a negative tolerance or
      #   headers that cannot be read
      def verify(raw_body, headers, secret, tolerance: DEFAULT_TOLERANCE, allow_simple: false, now: nil)
        Verifier.new(secret, headers, tolerance: tolerance, now: now).verify(raw_body, allow_simple: allow_simple)
      end

      # Verifies a delivery when the framework only gives the parsed JSON body.
      #
      # Only +X-Signature-V2+ and +X-Signature-V2-Previous+ can be checked: the other signatures
      # cover the exact body bytes. Prefer {verify} with the raw body whenever you have it.
      #
      # @param payload [Hash] the parsed JSON object, String or Symbol keys
      # @return [Event]
      # @raise (see verify)
      def verify_parsed(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
        Verifier.new(secret, headers, tolerance: tolerance, now: now).verify_parsed(payload)
      end

      # The canonical JSON of a parsed body, the text +X-Signature-V2+ signs: exactly Python's
      # +json.dumps(shorten_floats(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False)+.
      #
      # @param value [Hash, Array, String, Integer, Float, true, false, nil] parsed JSON
      # @return [String] UTF-8
      # @raise [ArgumentError] when +value+ is not JSON data (NaN, Infinity, a lone surrogate, ...)
      def canonical_json(value)
        CanonicalJson.generate(value)
      end

      # Builds the typed event of a payload WITHOUT verifying anything.
      #
      # For unsigned callbacks only, such as +kyb.registry_search.resolved+: anyone can send
      # such a request, so treat every field as untrusted and fetch the record from the API
      # before acting on it. {Event#verified_by} is nil and {Event#body_authenticated?} false.
      #
      # @param payload [Hash] the parsed JSON object
      # @return [Event]
      # @raise [ArgumentError] when +payload+ is not a Hash
      def parse_event(payload)
        raise ArgumentError, "parse_event needs the parsed JSON object (a Hash), not a #{payload.class}" unless payload.is_a?(Hash)

        Event.build(payload)
      end
    end
  end
end

require_relative "webhooks/canonical_json"
require_relative "webhooks/headers"
require_relative "webhooks/verifier"
require_relative "webhooks/events"
require_relative "webhooks/client_methods"
