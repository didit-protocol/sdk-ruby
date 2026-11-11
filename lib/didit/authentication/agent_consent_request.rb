# frozen_string_literal: true

module Didit
  class Authentication
    # Builds and checks the body of +POST agents/consent/+, and names the strings of it that
    # must never reach an error message: the challenge and the assertion's response members.
    #
    # @api private
    module AgentConsentRequest
      CONSENT_PATH = "/agents/consent/"
      OPTIONS_PATH = "/agents/consent/passkey/"
      DECISIONS = %w[approve deny].freeze
      # The assertion members that are secrets.
      ASSERTION_SECRETS = %w[clientDataJSON authenticatorData signature userHandle].freeze

      # @return [Array(Hash, Array<String>)] the JSON body and its secret strings
      # @raise [Didit::ConfigurationError]
      def self.build(challenge, decision, assertion, scopes)
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
        body["scopes"] = checked_scopes(scopes) unless scopes.nil?
        [body, secrets]
      end

      def self.checked_assertion(assertion)
        return assertion if assertion.is_a?(Hash)

        raise ConfigurationError, "assertion must be a Hash (the JSON-serialised WebAuthn assertion)."
      end

      def self.checked_scopes(scopes)
        return scopes if scopes.is_a?(Array) && !scopes.empty? && scopes.all? { |s| s.is_a?(String) && !s.empty? }

        raise ConfigurationError, "scopes must be a non-empty array of strings such as [\"read\", \"act\"]."
      end

      def self.assertion_secrets(assertion)
        response = assertion["response"] || assertion[:response]
        return [] unless response.is_a?(Hash)

        response.filter_map do |key, value|
          value if ASSERTION_SECRETS.include?(key.to_s) && value.is_a?(String) && !value.empty?
        end
      end
    end
  end
end
