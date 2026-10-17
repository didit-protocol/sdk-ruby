# frozen_string_literal: true

require "uri"

module Didit
  class Authentication
    # The issuer URL and the publishable key that carries it.
    #
    # An application's issuer is its canonical origin: +https://<slug>.auth.didit.me+
    # (live), +https://<slug>.sandbox.auth.didit.me+ (sandbox) or its active custom
    # domain, with no trailing slash. A publishable key is +pk_live_+ (live) or
    # +pk_test_+ (sandbox) followed by the unpadded base64url encoding of the issuer.
    # @api private
    module Issuer
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
      # Prefix => whether the key may name a plain http loopback issuer.
      PREFIXES = { "pk_live_" => false, "pk_test_" => true }.freeze
      UNSAFE = /[\s\x00-\x1f\x7f?#]/

      module_function

      # The issuer without trailing slashes.
      #
      # It must be an absolute https URL with no user name, password, query or
      # fragment. Plain http is accepted only for localhost, *.localhost,
      # 127.0.0.1 and ::1 (a local test stack) when +allow_loopback_http+ is true.
      #
      # @param issuer [String]
      # @return [String]
      # @raise [Didit::ConfigurationError]
      def normalize(issuer, allow_loopback_http: true)
        text = issuer.is_a?(String) ? issuer.strip : ""
        if text.empty?
          raise ConfigurationError,
                "The issuer is empty: pass your application's issuer (https://<slug>.auth.didit.me or your " \
                "custom domain) or use Didit::Authentication.from_publishable_key."
        end
        if PREFIXES.key?(text[0, 8])
          raise ConfigurationError, "That is a publishable key, not an issuer: use Didit::Authentication.from_publishable_key."
        end

        uri = parse(text)
        secure = uri.scheme.downcase == "https"
        local = allow_loopback_http && uri.scheme.downcase == "http" && loopback?(uri.hostname.to_s)
        unless secure || local
          raise ConfigurationError, "The issuer must use https (http only for localhost while testing), got #{text.inspect}."
        end

        text.sub(%r{/+\z}, "")
      end

      # The issuer a +pk_live_+ or +pk_test_+ publishable key carries. A live key
      # must name an https issuer; a test (sandbox) key may also name http on a
      # loopback host, as the console allows for sandbox applications.
      #
      # @param publishable_key [String]
      # @return [String]
      # @raise [Didit::ConfigurationError]
      def from_publishable_key(publishable_key)
        key = publishable_key.is_a?(String) ? publishable_key.strip : ""
        prefix = key[0, 8].to_s
        unless PREFIXES.key?(prefix)
          raise ConfigurationError,
                "A publishable key starts with pk_live_ or pk_test_; copy it from the Developers section of " \
                "Authentication in the Didit console."
        end

        normalize(decode_issuer(prefix, key[8..].to_s), allow_loopback_http: PREFIXES.fetch(prefix))
      end

      # Whether +host+ (without brackets) is a loopback name or address.
      def loopback?(host)
        host = host.downcase
        LOOPBACK_HOSTS.include?(host) || host.end_with?(".localhost")
      end

      def decode_issuer(prefix, encoded)
        raw = encoded.empty? ? nil : Base64Url.decode(encoded)
        issuer = raw&.force_encoding(Encoding::UTF_8)
        return issuer if issuer&.valid_encoding?

        raise ConfigurationError,
              "The publishable key is not valid: expected #{prefix} followed by the base64url-encoded issuer."
      end

      def parse(text)
        uri = text.match?(UNSAFE) ? nil : URI.parse(text)
        if uri.is_a?(URI::HTTP) && uri.userinfo
          raise ConfigurationError, "The issuer URL must not contain a user name or password."
        end
        return uri if uri.is_a?(URI::HTTP) && !uri.hostname.to_s.empty? && (1..65_535).cover?(uri.port)

        invalid(text)
      rescue URI::Error
        invalid(text)
      end

      def invalid(text)
        raise ConfigurationError, "The issuer must be an absolute https URL with no query or fragment, got #{text.inspect}."
      end
    end
  end
end
