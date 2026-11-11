# frozen_string_literal: true

module Didit
  class Authentication
    # Builds and checks the body of +POST agents/consent/+, and names the strings of it that
    # must never reach an error: the challenge and every string of the assertion.
    #
    # @api private
    module AgentConsentRequest
      CONSENT_PATH = "/agents/consent/"
      OPTIONS_PATH = "/agents/consent/passkey/"
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      LIFETIMES = [86_400, 604_800, 2_592_000].freeze
      DECISIONS = %w[approve deny].freeze
      # @return [Array(Hash, Array<String>)] the JSON body and its secret strings
      # @raise [Didit::ConfigurationError]
      def self.build(challenge, decision, assertion, scopes, extras = {})
        decision = decision.to_s
        unless DECISIONS.include?(decision)
          raise ConfigurationError, "decision must be \"approve\" or \"deny\", got #{decision.inspect}."
        end

        # @type var body: Hash[String, untyped]
        body = { "challenge" => challenge, "decision" => decision }
        body["assertion"] = checked_assertion(assertion) unless assertion.nil?
        body["scopes"] = checked_scopes(scopes) unless scopes.nil?
        organization_ids = extras[:organization_ids]
        lifetime = extras[:lifetime]
        body["organization_ids"] = checked_organization_ids(organization_ids) unless organization_ids.nil?
        body["lifetime"] = checked_lifetime(lifetime) unless lifetime.nil?
        # Encoded exactly once: the plain body decoded from these bytes is what is sent, and the secrets are
        # read from it, so a caller's object is never serialized a second time.
        body = JSON.parse(JSON.generate(body))
        [body, [challenge, *assertion_secrets(body["assertion"])]]
      end

      def self.checked_organization_ids(ids)
        valid = ids.is_a?(Array) && ids.size <= 100 && ids.all? { |id| id.is_a?(String) && UUID.match?(id) }
        return ids if valid

        raise ConfigurationError, "organization_ids must be an array of at most 100 UUID strings."
      end

      def self.checked_lifetime(lifetime)
        return lifetime if LIFETIMES.include?(lifetime)

        raise ConfigurationError, "lifetime must be one of #{LIFETIMES.join(", ")} (seconds), got #{lifetime.inspect}."
      end

      def self.checked_assertion(assertion)
        return assertion if assertion.is_a?(Hash)

        raise ConfigurationError, "assertion must be a Hash (the JSON-serialised WebAuthn assertion)."
      end

      def self.checked_scopes(scopes)
        return scopes if scopes.is_a?(Array) && !scopes.empty? && scopes.all? { |s| s.is_a?(String) && !s.empty? }

        raise ConfigurationError, "scopes must be a non-empty array of strings such as [\"read\", \"act\"]."
      end

      # Strings shorter than this are not secrets: field names such as "id" and values such as "public-key"
      # would otherwise erase error codes like "invalid_grant" (docs/DESIGN.md section 10).
      MIN_SECRET_LENGTH = 16

      # Every string of at least 16 characters inside the assertion, at any depth: object keys and values,
      # array items.
      def self.assertion_secrets(value)
        case value
        when String then value.length >= MIN_SECRET_LENGTH ? [value] : []
        when Hash then value.flat_map { |key, item| assertion_secrets(key.to_s) + assertion_secrets(item) }
        when Array then value.flat_map { |item| assertion_secrets(item) }
        else []
        end
      end
    end
  end
end
