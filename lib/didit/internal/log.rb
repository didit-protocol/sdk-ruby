# frozen_string_literal: true

module Didit
  module Internal
    # Debug logging (docs/DESIGN.md section 6): method, path, status, duration and request
    # id, never bodies, headers or query strings.
    # @api private
    module Log
      module_function

      def response(config, prepared, response, elapsed)
        return unless enabled?(config)

        request_id = Util.request_id(response.headers) || "-"
        write(config, format("%<method>s %<path>s -> %<status>d in %<ms>.0f ms (request id %<id>s)",
                             method: prepared.http_method.to_s.upcase, path: prepared.uri.path,
                             status: response.status, ms: elapsed * 1000, id: request_id))
      end

      def retry(config, prepared, reason, delay, retries_left)
        return unless enabled?(config)

        write(config, format("%<method>s %<path>s: %<reason>s; retrying in %<delay>.2f s (%<left>d retries left)",
                             method: prepared.http_method.to_s.upcase, path: prepared.uri.path, reason: reason,
                             delay: delay, left: retries_left))
      end

      def enabled?(config)
        !config.logger.nil? || Util.debug_from_env?
      end

      def write(config, message)
        if config.logger
          config.logger.debug("didit") { message }
        else
          $stderr.puts("[didit] #{message}") # rubocop:disable Style/StderrPuts
        end
      end
    end
  end
end
