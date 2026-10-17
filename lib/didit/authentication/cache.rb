# frozen_string_literal: true

module Didit
  class Authentication
    # The parts of +/.well-known/openid-configuration+ the SDK uses.
    # @api private
    class Discovery
      # @return [String]
      attr_reader :issuer
      # @return [String]
      attr_reader :token_endpoint
      # @return [String]
      attr_reader :jwks_uri
      # @return [Hash] the document as the issuer sent it (frozen)
      attr_reader :document

      def initialize(issuer:, token_endpoint:, jwks_uri:, document:)
        @issuer = issuer
        @token_endpoint = token_endpoint
        @jwks_uri = jwks_uri
        @document = IssuerCache.deep_freeze(document)
        freeze
      end
    end

    # What is cached for one issuer, and when to fetch again (no I/O here).
    #
    # The discovery document and the key set are cached for the response's
    # +Cache-Control: max-age+ less its +Age+ (Didit sends +public, max-age=300+),
    # five minutes when the header is absent, a minute for +no-store+ and
    # +no-cache+, and never less than a minute or more than a day. A token whose
    # +kid+ is not in the cached key set triggers a refetch only when the last
    # fetch, successful or failed, is at least a minute old. After a failed
    # fetch, verification that needs the keys fails fast for a minute instead of
    # fetching again for every token.
    #
    # The caller holds a lock around fetches; reads of a fresh entry need none,
    # because entries are replaced, never changed.
    # @api private
    class IssuerCache
      DEFAULT_MAX_AGE = 300
      MIN_MAX_AGE = 60
      MAX_MAX_AGE = 86_400
      REFETCH_INTERVAL = 60
      NO_CACHE = %w[no-store no-cache].freeze

      # A cached value and the clock reading it expires at.
      class Entry
        attr_reader :value, :expires_at

        def initialize(value, expires_at)
          @value = value
          @expires_at = expires_at
          freeze
        end
      end

      class << self
        # How long a discovery or JWKS response may be kept, in seconds.
        #
        # @param headers [Hash{String => String}] names in lower case
        # @return [Integer]
        def cache_seconds(headers)
          max_age = max_age(headers.fetch("cache-control", ""))
          return DEFAULT_MAX_AGE if max_age.nil?

          age = Integer(headers.fetch("age", "").strip, 10, exception: false) || 0
          (max_age - age).clamp(MIN_MAX_AGE, MAX_MAX_AGE)
        end

        # A deeply frozen copy of a parsed JSON value.
        def deep_freeze(value)
          case value
          when Hash then value.to_h { |key, item| [key.dup.freeze, deep_freeze(item)] }.freeze
          when Array then value.map { |item| deep_freeze(item) }.freeze
          when String then value.dup.freeze
          else value
          end
        end

        private

        # The max-age directive, 0 for no-store and no-cache, nil without either.
        def max_age(cache_control)
          max_age = nil
          cache_control.split(",").each do |directive|
            name, value = directive.split("=", 2)
            name = name.to_s.strip.downcase
            return 0 if NO_CACHE.include?(name)

            if name == "max-age"
              seconds = Integer(value.to_s.strip.delete_prefix('"').delete_suffix('"'), 10, exception: false)
              max_age = seconds if seconds
            end
          end
          max_age
        end
      end

      # @param clock [#call] returns the current time in seconds
      def initialize(clock)
        @clock = clock
        @discovery = nil
        @key_set = nil
        @key_set_attempted_at = nil
        @key_set_failed = false
      end

      # The cached discovery document while it is fresh.
      #
      # @return [Discovery, nil]
      def discovery
        fresh(@discovery)
      end

      # @return [Discovery]
      def store_discovery(discovery, headers)
        @discovery = Entry.new(discovery, now + IssuerCache.cache_seconds(headers))
        discovery
      end

      # The cached key set while it is fresh.
      #
      # @return [KeySet, nil]
      def key_set
        fresh(@key_set)
      end

      # @return [KeySet]
      def store_key_set(key_set, headers)
        at = now
        @key_set = Entry.new(key_set, at + IssuerCache.cache_seconds(headers))
        @key_set_attempted_at = at
        @key_set_failed = false
        key_set
      end

      # Notes a fetch of the key set (or of the discovery document before it) that failed.
      def key_set_fetch_failed
        @key_set_attempted_at = now
        @key_set_failed = true
        nil
      end

      # No key set is fresh and the last fetch failed less than a minute ago.
      def key_set_unavailable?
        attempted_at = @key_set_attempted_at
        return false unless @key_set_failed && attempted_at && key_set.nil?

        now - attempted_at < REFETCH_INTERVAL
      end

      # The fresh key set when it has +kid+: the lock-free fast path.
      #
      # @return [KeySet, nil]
      def key_set_with(kid)
        current = key_set
        current if current&.key?(kid)
      end

      # Whether verifying a token signed with +kid+ should fetch the key set: when
      # none is fresh, or when +kid+ is unknown and the last fetch, successful or
      # failed, was at least {REFETCH_INTERVAL} seconds ago. A nil +kid+ asks for
      # any fresh key set. Check {#key_set_unavailable?} first.
      def needs_key_set_fetch?(kid)
        current = key_set
        return true if current.nil?
        return false if kid.nil? || current.key?(kid)

        attempted_at = @key_set_attempted_at
        attempted_at.nil? || now - attempted_at >= REFETCH_INTERVAL
      end

      private

      def fresh(entry)
        entry.value if entry && now < entry.expires_at
      end

      def now
        @clock.call.to_f
      end
    end
  end
end
