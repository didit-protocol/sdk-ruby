# frozen_string_literal: true

module Didit
  module Webhooks
    # Adds {Didit::Webhooks.verify} and {Didit::Webhooks.verify_parsed} to +client.webhooks+,
    # next to +client.webhooks.destinations+. They need no API key and send no request.
    module ClientMethods
      # See {Didit::Webhooks.verify}.
      #
      # @return [Event]
      def verify(raw_body, headers, secret, tolerance: DEFAULT_TOLERANCE, allow_simple: false, now: nil)
        Webhooks.verify(raw_body, headers, secret, tolerance: tolerance, allow_simple: allow_simple, now: now)
      end

      # See {Didit::Webhooks.verify_parsed}.
      #
      # @return [Event]
      def verify_parsed(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
        Webhooks.verify_parsed(payload, headers, secret, tolerance: tolerance, now: now)
      end
    end
  end
end
