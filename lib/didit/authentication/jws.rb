# frozen_string_literal: true

require "json"
require "jwt"
require "openssl"

module Didit
  class Authentication
    # JWS parsing and claim checks for Didit Authentication tokens (no I/O here).
    #
    # Didit issuers sign with ES256 only: access tokens carry the header
    # +typ: at+jwt+ and ID tokens +typ: JWT+. Every other algorithm, +none+
    # included, is refused before any key is looked up.
    # @api private
    module Jws
      ALGORITHM = "ES256"
      MAX_TOKEN_LENGTH = 16_384
      ACCESS_TYPES = %w[at+jwt application/at+jwt].freeze
      ID_TYPES = %w[jwt application/jwt].freeze
      ZERO = ("\x00" * 32).b.freeze
      JSON_OPTIONS = { allow_nan: false, max_nesting: 64 }.merge(
        # json 2.13 and newer can refuse duplicate member names; older versions keep the last one.
        Gem::Version.new(JSON::VERSION) >= Gem::Version.new("2.13.0") ? { allow_duplicate_key: false } : {}
      ).freeze
      # Every check below is done here; the jwt gem only checks the signature.
      DECODE_OPTIONS = {
        algorithm: ALGORITHM, verify_expiration: false, verify_not_before: false, verify_iat: false,
        verify_iss: false, verify_aud: false, verify_jti: false, verify_sub: false, required_claims: []
      }.freeze

      # A compact JWS whose header passed the algorithm, type and key id checks; not verified yet.
      class Parsed
        attr_reader :token, :header, :claims, :signature, :kid

        def initialize(token:, header:, claims:, signature:, kid:)
          @token = token
          @header = header
          @claims = claims
          @signature = signature
          @kid = kid
          freeze
        end
      end

      module_function

      # Splits and decodes a compact JWS and checks its header (+alg+, +crit+,
      # +typ+, +kid+). Nothing in it is trusted until the signature is checked.
      #
      # @param token [Object]
      # @param kind [Symbol] +:access+ or +:id+
      # @return [Parsed]
      # @raise [Didit::TokenVerificationError]
      def parse(token, kind)
        fail!(:malformed, "The token is empty or not a string.") unless token.is_a?(String) && !token.empty?
        if token.bytesize > MAX_TOKEN_LENGTH
          fail!(:malformed, "The token is longer than #{MAX_TOKEN_LENGTH} characters.")
        end

        parts = token.b.split(".", -1)
        fail!(:malformed, "The token is not a compact JWS (three dot-separated segments).") unless parts.length == 3

        header_segment, payload_segment, signature_segment = parts
        header = json_object(header_segment.to_s, "header")
        check_header(header, kind)
        claims = json_object(payload_segment.to_s, "payload")
        signature = Base64Url.decode(signature_segment.to_s)
        fail!(:malformed, "The token signature is not base64url.") if signature.nil?

        Parsed.new(token: parts.join("."), header: header, claims: claims, signature: signature, kid: header["kid"])
      end

      # Checks the ES256 signature with +key+, through the jwt gem.
      #
      # @param parsed [Parsed]
      # @param key [OpenSSL::PKey::EC]
      # @raise [Didit::TokenVerificationError]
      def verify_signature(parsed, key)
        signature = parsed.signature
        # The JWS form only: the 32-byte R then the 32-byte S, neither zero. A DER signature is refused.
        unless signature.bytesize == 64 && signature.byteslice(0, 32) != ZERO && signature.byteslice(32, 32) != ZERO
          fail!(:invalid_signature, "The token's signature is not a 64-byte ES256 signature (R || S).")
        end

        JWT.decode(parsed.token, key, true, DECODE_OPTIONS)
        nil
      rescue JWT::IncorrectAlgorithm
        fail!(:unsupported_algorithm, "The token is not signed with ES256.")
      rescue JWT::VerificationError, OpenSSL::PKey::PKeyError
        fail!(:invalid_signature, "The token's signature does not verify with the issuer's key.")
      rescue JWT::DecodeError, JSON::ParserError
        fail!(:malformed, "The token could not be decoded.")
      end

      # Checks the registered claims of a token whose signature is verified.
      #
      # +iss+ must equal +issuer+; +sub+, +exp+ and +iat+ must be present; +exp+,
      # +nbf+ and +iat+ are compared with +now+ allowing +leeway+ seconds of clock
      # skew; +aud+ must contain one of +audience+ when it is given; an ID token's
      # +nonce+ must equal +nonce+, or be absent when +nonce+ is nil.
      #
      # @param claims [Hash]
      # @param kind [Symbol] +:access+ or +:id+
      # @param issuer [String]
      # @param audience [Array<String>, nil]
      # @param nonce [String, nil]
      # @param leeway [Float]
      # @param now [Float]
      # @raise [Didit::TokenVerificationError]
      def check_claims(claims, kind:, issuer:, audience:, nonce:, leeway:, now:)
        check_issuer(claims, issuer)
        sub = claims["sub"]
        fail!(:missing_claim, "The token has no sub claim.") unless sub.is_a?(String) && !sub.empty?

        check_times(claims, leeway, now)
        check_audience(claims, audience) if audience
        check_nonce(claims, nonce) if kind == :id
        nil
      end

      # A short, safe rendering of a header or claim value for an error message.
      def shown(value)
        text = value.inspect
        text.length <= 64 ? text : "#{text[0, 61]}..."
      end

      def fail!(reason, message)
        raise TokenVerificationError.new(reason, message)
      end

      def json_object(segment, part)
        raw = Base64Url.decode(segment)
        fail!(:malformed, "The token #{part} is not base64url.") if raw.nil?

        text = raw.force_encoding(Encoding::UTF_8)
        fail!(:malformed, "The token #{part} is not UTF-8.") unless text.valid_encoding?

        value = JSON.parse(text, **JSON_OPTIONS)
        fail!(:malformed, "The token #{part} is not a JSON object.") unless value.is_a?(Hash)

        value
      rescue JSON::ParserError, EncodingError
        fail!(:malformed, "The token #{part} is not valid JSON.")
      end

      def check_header(header, kind)
        alg = header["alg"]
        if alg != ALGORITHM
          fail!(:unsupported_algorithm, "The token is signed with #{shown(alg)}; only ES256 is accepted.")
        end
        if header.key?("crit")
          fail!(:malformed, "The token header has critical extensions (crit), which are not supported.")
        end

        check_type(header["typ"], kind)
        kid = header["kid"]
        fail!(:malformed, "The token header names no signing key (kid).") unless kid.is_a?(String) && !kid.empty?
      end

      def check_type(typ, kind)
        if kind == :access
          return if typ.is_a?(String) && ACCESS_TYPES.include?(typ.downcase)

          fail!(:invalid_type, "The token is not an access token: its header typ is #{shown(typ)}, not \"at+jwt\".")
        end
        # ID tokens carry typ JWT; refusing at+jwt keeps an access token from passing as one.
        return if typ.nil? || (typ.is_a?(String) && ID_TYPES.include?(typ.downcase))

        fail!(:invalid_type, "The token is not an ID token: its header typ is #{shown(typ)}, not \"JWT\".")
      end

      def check_issuer(claims, issuer)
        iss = claims["iss"]
        fail!(:missing_claim, "The token has no iss claim.") if iss.nil?
        fail!(:invalid_issuer, "The token was issued by #{shown(iss)}, not by #{issuer.inspect}.") if iss != issuer
      end

      def check_times(claims, leeway, now)
        exp = numeric_date(claims, "exp")
        iat = numeric_date(claims, "iat")
        nbf = claims.key?("nbf") ? numeric_date(claims, "nbf") : nil
        fail!(:expired, "The token has expired.") if now >= exp + leeway
        fail!(:not_yet_valid, "The token is not valid yet (nbf is in the future).") if nbf && now + leeway < nbf
        fail!(:invalid_issued_at, "The token was issued in the future (iat).") if now + leeway < iat
      end

      def numeric_date(claims, name)
        fail!(:missing_claim, "The token has no #{name} claim.") unless claims.key?(name)

        value = claims[name]
        seconds = case value
                  when Float then value
                  # An integer beyond any Float is as unusable as NaN.
                  when Integer then value.abs < Float::MAX ? value.to_f : Float::NAN
                  else Float::NAN
                  end
        fail!(:malformed, "The token's #{name} claim is not a number of seconds.") unless seconds.finite?

        seconds
      end

      def check_audience(claims, audience)
        fail!(:missing_claim, "The token has no aud claim.") unless claims.key?("aud")

        aud = claims["aud"]
        values = case aud
                 when String then [aud]
                 when Array then aud.grep(String)
                 else []
                 end
        fail!(:invalid_audience, "The token was not issued for this audience.") unless values.intersect?(audience)
      end

      def check_nonce(claims, nonce)
        token_nonce = claims["nonce"]
        if nonce.nil?
          return if token_nonce.nil?

          fail!(:invalid_nonce, "The ID token carries a nonce: pass the nonce this sign-in started with.")
        end
        return if token_nonce.is_a?(String) && OpenSSL.secure_compare(token_nonce, nonce)

        fail!(:invalid_nonce, "The ID token's nonce does not match this sign-in.")
      end
    end
  end
end
