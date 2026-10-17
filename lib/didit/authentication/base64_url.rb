# frozen_string_literal: true

module Didit
  class Authentication
    # Unpadded base64url (RFC 4648 section 5) with strict decoding.
    # @api private
    module Base64Url
      ALPHABET = /\A[A-Za-z0-9_-]*\z/

      module_function

      # @param bytes [String]
      # @return [String]
      def encode(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      # The bytes of canonical unpadded base64url, else nil: no padding, no
      # characters outside the alphabet, no impossible length, no stray bits.
      #
      # @param text [String]
      # @return [String, nil] binary
      def decode(text)
        text = text.b
        return nil unless ALPHABET.match?(text) && text.length % 4 != 1

        (text.tr("-_", "+/") + ("=" * (-text.length % 4))).unpack1("m0")
      rescue ArgumentError
        nil
      end
    end
  end
end
