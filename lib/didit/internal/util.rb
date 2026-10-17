# frozen_string_literal: true

require "uri"

module Didit
  module Internal
    # Small helpers shared by the client, webhooks and Authentication.
    # @api private
    module Util
      REQUEST_ID_HEADERS = %w[x-request-id request-id x-amzn-requestid x-correlation-id].freeze
      REDACTED = "[redacted]"

      module_function

      # +User-Agent: didit-ruby/<version> (<engine> <version>; <platform>)+ (docs/DESIGN.md section 6).
      def user_agent
        "didit-ruby/#{Didit::VERSION} (#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION}; #{RUBY_PLATFORM})"
      end

      # +X-Didit-Client: ruby/<version>+.
      def client_header
        "ruby/#{Didit::VERSION}"
      end

      # The request id from response headers (names in lower case), if any.
      def request_id(headers)
        REQUEST_ID_HEADERS.each do |name|
          value = headers[name]
          return value unless value.nil? || value.empty?
        end
        nil
      end

      # Replaces every secret in +value+ (a String, or Hash/Array of them) with "[redacted]".
      def redact(value, secrets)
        secrets = secrets.compact.reject(&:empty?)
        return value if secrets.empty?

        redact_value(value, secrets)
      end

      def redact_value(value, secrets)
        case value
        when String then secrets.reduce(value) { |text, secret| text.gsub(secret, REDACTED) }
        when Hash then value.to_h { |k, v| [redact_value(k, secrets), redact_value(v, secrets)] }
        when Array then value.map { |v| redact_value(v, secrets) }
        else value
        end
      end

      # +scheme://host[:port]+ with the default port left out.
      def origin(uri)
        uri = URI(uri) unless uri.is_a?(URI::Generic)
        default = { "http" => 80, "https" => 443 }[uri.scheme]
        port = uri.port.nil? || uri.port == default ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host&.downcase}#{port}"
      end

      # The URL without query string, fragment or credentials (for errors and logs).
      def display_url(uri)
        uri = URI(uri) unless uri.is_a?(URI::Generic)
        "#{origin(uri)}#{uri.path}"
      end

      # Whether the environment variable asks for debug logging.
      def debug_from_env?
        ENV.fetch("DIDIT_LOG", "").strip.casecmp?("debug")
      end
    end
  end
end
