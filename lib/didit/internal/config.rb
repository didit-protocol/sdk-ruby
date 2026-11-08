# frozen_string_literal: true

require "uri"

module Didit
  module Internal
    # The resolved, immutable options of a Didit::Client (docs/DESIGN.md section 6).
    # @api private
    class Config
      DEFAULT_BASE_URL = "https://verification.didit.me"
      DEFAULT_ACCOUNT_BASE_URL = "https://apx.didit.me/auth/v2"
      DEFAULT_TIMEOUT = 60.0
      DEFAULT_MAX_RETRIES = 2
      FIELDS = %i[
        api_key account_token organization_id application_id base_url account_base_url timeout max_retries
        default_headers logger http_client
      ].freeze

      attr_reader(*FIELDS)

      def initialize(**options)
        unknown = options.keys - FIELDS
        raise ConfigurationError, "Unknown client options #{unknown.map(&:inspect).join(", ")}." unless unknown.empty?

        @api_key, @account_token, @organization_id, @application_id =
          options.values_at(:api_key, :account_token, :organization_id, :application_id).map { |v| present(v) }
        @base_url = Config.check_url(:base_url, options[:base_url] || DEFAULT_BASE_URL)
        @account_base_url = Config.check_url(:account_base_url, options[:account_base_url] || DEFAULT_ACCOUNT_BASE_URL)
        @timeout = Config.check_timeout(options.fetch(:timeout, DEFAULT_TIMEOUT))
        @max_retries = Config.check_max_retries(options.fetch(:max_retries, DEFAULT_MAX_RETRIES))
        @default_headers = check_headers(options[:default_headers] || {})
        @logger = options[:logger]
        @http_client = check_http_client(options[:http_client])
        freeze
      end

      # A copy with +changes+ applied; a nil value clears an id or token.
      def merge(changes)
        Config.new(**FIELDS.to_h { |f| [f, public_send(f)] }, **changes)
      end

      def self.check_url(name, url)
        uri = URI(url.to_s)
        unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? && uri.query.nil? &&
               uri.fragment.nil? && uri.userinfo.nil?
          raise ConfigurationError, "#{name} must be an absolute http(s) URL without query or credentials, " \
                                    "got #{url.to_s.inspect}."
        end

        uri.to_s.sub(%r{/+\z}, "")
      rescue URI::InvalidURIError
        raise ConfigurationError, "#{name} must be an absolute http(s) URL, got #{url.to_s.inspect}."
      end

      def self.check_timeout(value)
        unless value.is_a?(Numeric) && value.positive? && value.finite?
          raise ConfigurationError, "timeout must be a positive number of seconds, got #{value.inspect}."
        end

        (_ = value).to_f
      end

      def self.check_max_retries(value)
        unless value.is_a?(Integer) && !value.negative?
          raise ConfigurationError, "max_retries must be an Integer of 0 or more, got #{value.inspect}."
        end

        value
      end

      private

      def present(value)
        return nil if value.nil?

        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def check_headers(headers)
        raise ConfigurationError, "default_headers must be a Hash." unless headers.is_a?(Hash)

        headers.to_h { |k, v| [k.to_s, v&.to_s] }.freeze
      end

      def check_http_client(value)
        return nil if value.nil?
        return value if value.respond_to?(:call)

        raise ConfigurationError, "http_client must respond to call(uri) and return a Net::HTTP."
      end
    end
  end
end
