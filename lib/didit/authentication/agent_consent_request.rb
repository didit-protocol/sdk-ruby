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
        secrets = [challenge]
        unless assertion.nil?
          body["assertion"] = checked_assertion(assertion)
          secrets.concat(assertion_secrets(assertion))
        end
        secrets = with_escaped_forms(secrets)
        body["scopes"] = checked_scopes(scopes) unless scopes.nil?
        organization_ids = extras[:organization_ids]
        lifetime = extras[:lifetime]
        body["organization_ids"] = checked_organization_ids(organization_ids) unless organization_ids.nil?
        body["lifetime"] = checked_lifetime(lifetime) unless lifetime.nil?
        [body, secrets]
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

      # Every non-empty string value inside the assertion, at any depth (hash values, array items).
      def self.assertion_secrets(value)
        case value
        when String then value.empty? ? [] : [value]
        when Hash then value.values.flat_map { |item| assertion_secrets(item) }
        when Array then value.flat_map { |item| assertion_secrets(item) }
        else []
        end
      end

      # Each secret plus its JSON-escaped form (as it appears inside a raw JSON body), longest first
      # so a secret that contains another is replaced whole.
      def self.with_escaped_forms(secrets)
        forms = secrets.flat_map { |secret| [secret, JSON.generate(secret)[1..-2].to_s] }
        forms.reject(&:empty?).uniq.sort_by { |secret| -secret.length }
      end
    end
  end
end
