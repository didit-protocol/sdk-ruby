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

      # Redacts a parsed JSON value structurally: every string (object key or value) that contains a secret
      # anywhere in it becomes "[redacted]" as a whole. Strings are compared as decoded, so the spelling
      # of the raw JSON text does not matter. A redacted key that collides with another key is numbered.
      def redact_structured(value, secrets)
        secrets = secrets.compact.reject(&:empty?)
        case value
        when String then secrets.any? { |secret| value.include?(secret) } ? REDACTED : value
        when Array then value.map { |item| redact_structured(item, secrets) }
        when Hash then redact_structured_hash(value, secrets)
        else value
        end
      end

      def redact_structured_hash(value, secrets)
        # Reserve every safe key name first, so a placeholder never takes one.
        taken = value.keys.select { |key| redact_structured(key, secrets) == key }
        number = 1
        # @type var result: Hash[untyped, untyped]
        result = {}
        value.each do |key, item|
          name = key
          if redact_structured(key, secrets) != key
            loop do
              name = number == 1 ? REDACTED : "#{REDACTED}#{number}"
              number += 1
              break unless taken.include?(name)
            end
            taken << name
          end
          result[name] = redact_structured(item, secrets)
        end
        result
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

      # Sleeps between retries (a separate method, so tests can skip the wait).
      def pause(seconds)
        Kernel.sleep(seconds) if seconds.positive?
      end

      # Whether the environment variable asks for debug logging.
      def debug_from_env?
        ENV.fetch("DIDIT_LOG", "").strip.casecmp?("debug")
      end
    end
  end
end
