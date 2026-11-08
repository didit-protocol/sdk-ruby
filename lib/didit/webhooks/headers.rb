# frozen_string_literal: true

module Didit
  module Webhooks
    # The webhook headers of a request, read from whatever the framework has.
    #
    # Accepts a Hash with header names in any case, a Rack env (+HTTP_X_SIGNATURE_V2+, which is
    # also what Rails +request.headers+ and Sinatra +request.env+ yield), or any object whose
    # +each+ yields +[name, value]+ pairs (Net::HTTPHeader, an Array of pairs). Values may be
    # Strings or Arrays of Strings. Empty values count as absent.
    #
    # @api private
    class Headers
      # Header names (lower case) the verifier reads.
      WANTED = [
        HEADER_SIGNATURE, HEADER_SIGNATURE_V2, HEADER_SIGNATURE_SIMPLE,
        HEADER_SIGNATURE_PREVIOUS, HEADER_SIGNATURE_V2_PREVIOUS, HEADER_SIGNATURE_SIMPLE_PREVIOUS,
        HEADER_TIMESTAMP
      ].map(&:downcase).freeze

      # A well-formed signature: 64 lowercase hex characters.
      HEX = /\A[0-9a-f]{64}\z/

      # @raise [Didit::ConfigurationError] when +source+ cannot be enumerated
      def initialize(source)
        unless source.respond_to?(:each)
          raise ConfigurationError,
                "headers must be a Hash, a Rack env or [name, value] pairs, not #{source.class}."
        end

        @values = {}
        source.each { |name, value| add(name, value) }
      end

      # Whether the header has a non-empty value.
      def present?(name)
        !parts(name).empty?
      end

      # The well-formed signatures a header carries. A proxy may have joined repeated
      # headers with commas, so every comma-separated part counts.
      def signatures(name)
        parts(name).grep(HEX)
      end

      # The first non-empty value of +X-Timestamp+, stripped.
      def timestamp
        values(HEADER_TIMESTAMP).first
      end

      private

      def add(name, value)
        key = header_key(name)
        return unless key && WANTED.include?(key)

        (value.is_a?(Array) ? value : [value]).each do |item|
          item = item.to_s if item.is_a?(Integer)
          next unless item.is_a?(String)

          text = item.b.strip
          (@values[key] ||= []) << text unless text.empty?
        end
      end

      def header_key(name)
        name = name.name if name.is_a?(Symbol)
        return unless name.is_a?(String)

        key = name.b.strip.downcase
        key.start_with?("http_") ? key.delete_prefix("http_").tr("_", "-") : key
      end

      def values(name)
        @values.fetch(name.downcase, [])
      end

      def parts(name)
        values(name).flat_map { |value| value.split(",").map(&:strip) }.reject(&:empty?)
      end
    end
  end
end
