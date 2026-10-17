# frozen_string_literal: true

require "openssl"

module Didit
  class Authentication
    # The issuer's published ES256 keys by +kid+.
    # @api private
    class KeySet
      # DER SubjectPublicKeyInfo header (id-ecPublicKey, prime256v1) of an uncompressed P-256 point.
      SPKI_PREFIX = ["3059301306072a8648ce3d020106082a8648ce3d030107034200"].pack("H*").freeze
      UNCOMPRESSED = "\x04".b.freeze

      class << self
        # The key set, or nil when +data+ is not a JWKS (+{"keys": [...]}+).
        #
        # Only EC P-256 keys with +use+ "sig" (or none) and +alg+ "ES256" (or none)
        # and a non-empty string +kid+ are kept; the first usable key per kid wins.
        #
        # @param data [Object] the parsed JWKS
        # @return [KeySet, nil]
        def parse(data)
          return nil unless data.is_a?(Hash) && data["keys"].is_a?(Array)

          keys = {} # : Hash[String, OpenSSL::PKey::EC]
          data["keys"].each do |jwk|
            next unless jwk.is_a?(Hash)

            kid = jwk["kid"]
            next unless kid.is_a?(String) && !kid.empty? && !keys.key?(kid)

            key = p256_key(jwk)
            keys[kid] = key if key
          end
          new(keys, data)
        end

        # The public key of a P-256 signing JWK, or nil for any other or invalid key.
        #
        # @param jwk [Hash]
        # @return [OpenSSL::PKey::EC, nil]
        def p256_key(jwk)
          return nil unless jwk["kty"] == "EC" && jwk["crv"] == "P-256"
          return nil unless jwk.fetch("use", "sig") == "sig" && jwk.fetch("alg", Jws::ALGORITHM) == Jws::ALGORITHM

          x = coordinate(jwk["x"])
          y = coordinate(jwk["y"])
          return nil unless x && y

          # Reading the point as a SubjectPublicKeyInfo checks that it is on the curve.
          key = OpenSSL::PKey.read(SPKI_PREFIX + UNCOMPRESSED + x + y)
          key if key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == "prime256v1"
        rescue OpenSSL::PKey::PKeyError, ArgumentError
          nil
        end

        private

        # A P-256 coordinate: unpadded base64url of exactly 32 bytes (RFC 7518 section 6.2.1.2).
        def coordinate(value)
          raw = value.is_a?(String) ? Base64Url.decode(value) : nil
          raw if raw && raw.bytesize == 32
        end
      end

      # @return [Hash] the JWKS as the issuer sent it (frozen)
      attr_reader :document

      # @param keys [Hash{String => OpenSSL::PKey::EC}]
      # @param document [Hash]
      def initialize(keys, document)
        @keys = keys.freeze
        @document = IssuerCache.deep_freeze(document)
        freeze
      end

      # @param kid [String]
      # @return [OpenSSL::PKey::EC, nil]
      def [](kid)
        @keys[kid]
      end

      # @param kid [String]
      def key?(kid)
        @keys.key?(kid)
      end
    end
  end
end
