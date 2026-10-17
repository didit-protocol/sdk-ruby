# frozen_string_literal: true

require "digest"
require "securerandom"

module Didit
  class Authentication
    # A PKCE verifier and its S256 challenge (RFC 7636).
    #
    # Send {#code_challenge} and {#code_challenge_method} with the authorization
    # request, keep {#code_verifier} on your server (it is left out of {#inspect})
    # and pass it to {Authentication#exchange_code}.
    class Pkce
      METHOD = "S256"
      VERIFIER = /\A[A-Za-z0-9\-._~]{43,128}\z/

      # @return [String] keep it server-side; never send it to the browser
      attr_reader :code_verifier
      # @return [String] BASE64URL(SHA256(code_verifier))
      attr_reader :code_challenge
      # @return [String] always "S256"
      attr_reader :code_challenge_method

      # A new random verifier (32 random bytes, 43 characters) and its challenge.
      #
      # @return [Pkce]
      def self.generate
        new(SecureRandom.urlsafe_base64(32))
      end

      # +BASE64URL(SHA256(ASCII(verifier)))+ without padding (RFC 7636 section 4.2).
      #
      # @param verifier [String]
      # @return [String]
      def self.s256_challenge(verifier)
        Base64Url.encode(Digest::SHA256.digest(verifier))
      end

      # @param code_verifier [String] 43 to 128 characters of A-Z, a-z, 0-9, "-", ".", "_" and "~"
      # @raise [Didit::ConfigurationError] when the verifier does not fit RFC 7636 section 4.1
      def initialize(code_verifier)
        unless code_verifier.is_a?(String) && VERIFIER.match?(code_verifier)
          raise ConfigurationError, "A PKCE code_verifier is 43 to 128 characters of A-Z, a-z, 0-9, '-', '.', '_' and '~'."
        end

        @code_verifier = code_verifier.dup.freeze
        @code_challenge = Pkce.s256_challenge(code_verifier).freeze
        @code_challenge_method = METHOD
        freeze
      end

      # @return [Hash{Symbol => String}]
      def to_h
        { code_verifier: code_verifier, code_challenge: code_challenge, code_challenge_method: code_challenge_method }
      end

      def inspect
        "#<#{self.class.name} code_challenge=#{code_challenge.inspect} code_challenge_method=#{METHOD.inspect}>"
      end
      alias to_s inspect
    end
  end
end
