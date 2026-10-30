# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "zlib"

module Didit
  module Internal
    # Sends HTTP requests over persistent net/http connections, one small pool per origin.
    # Thread safe and fork safe: a child process never reuses its parent's sockets.
    # @api private
    class Transport
      # What came back: status, headers (lower-case names) and the body bytes.
      Response = Struct.new(:status, :headers, :body, keyword_init: true)

      # Raised by {#execute} when no response arrived; +sent+ says whether the request may
      # have reached the server.
      class Failure < StandardError
        attr_reader :error, :sent

        def initialize(error, sent:)
          super(error.message)
          @error = error
          @sent = sent
        end

        def timeout?
          TIMEOUT_ERRORS.any? { |klass| error.is_a?(klass) }
        end
      end

      # Errors that happen before any byte of the request leaves this process.
      NOT_SENT_ERRORS = [
        Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
        SocketError
      ].freeze
      # Errors after which the request may have reached the server.
      TRANSPORT_ERRORS = [
        Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, EOFError, IOError, SystemCallError,
        OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
      ].freeze
      TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, Errno::ETIMEDOUT].freeze
      MAX_IDLE = 8

      METHODS = {
        get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete, head: Net::HTTP::Head, options: Net::HTTP::Options
      }.freeze

      # @param http_client [#call, nil] returns a configured, not yet started Net::HTTP for a URI
      def initialize(http_client: nil)
        @http_client = http_client
        @mutex = Mutex.new
        @idle = {}
        @pid = Process.pid
      end

      attr_reader :http_client

      # Sends one request. With a block, a 2xx body is yielded in chunks instead of returned.
      #
      # @return [Response]
      # @raise [Failure]
      def execute(http_method, uri, headers, body, timeout, &)
        http = checkout(uri, timeout)
        reusable = false
        begin
          request = build(http_method, uri, headers, body)
          response = perform(http, request, &)
          reusable = response.headers["connection"]&.casecmp?("close") != true
          response
        rescue *NOT_SENT_ERRORS => e
          raise Failure.new(e, sent: false)
        rescue *TRANSPORT_ERRORS => e
          raise Failure.new(e, sent: true)
        ensure
          reusable ? checkin(uri, http) : discard(http)
        end
      end

      # Closes every idle connection.
      def close
        sessions = @mutex.synchronize do
          all = @idle.values.flatten
          @idle = {}
          all
        end
        sessions.each { |http| discard(http) }
        nil
      end

      private

      def perform(http, request, &block)
        # @type var result: Response?
        result = nil
        http.request(request) do |res|
          # @type var headers: Hash[String, String]
          headers = {}
          res.each_header { |name, value| headers[name.downcase] = value }
          status = res.code.to_i
          if block && status.between?(200, 299)
            res.read_body(&block)
            result = Response.new(status: status, headers: headers, body: nil)
          else
            result = Response.new(status: status, headers: headers, body: res.read_body.to_s.b)
          end
        end
        result || raise(Net::HTTPBadResponse, "no response")
      end

      def build(http_method, uri, headers, body)
        klass = METHODS.fetch(http_method)
        request = klass.new(target(uri), headers)
        request.body = body if body
        request
      end

      # The request target: path ("/" when empty) and query.
      def target(uri)
        path = uri.path.to_s.empty? ? "/" : uri.path.to_s
        uri.query ? "#{path}?#{uri.query}" : path
      end

      def checkout(uri, timeout)
        key = pool_key(uri)
        http = @mutex.synchronize do
          reset_after_fork
          @idle[key]&.pop
        end
        http ||= new_session(uri)
        configure(http, timeout)
        start(http) unless http.started?
        http
      end

      def start(http)
        http.start
      rescue *NOT_SENT_ERRORS, *TRANSPORT_ERRORS => e
        # Nothing was sent: the connection itself failed.
        discard(http)
        raise Failure.new(e, sent: false)
      end

      def checkin(uri, http)
        keep = @mutex.synchronize do
          list = (@idle[pool_key(uri)] ||= [])
          if @pid == Process.pid && list.size < MAX_IDLE
            list.push(http)
            true
          else
            false
          end
        end
        discard(http) unless keep
      end

      def discard(http)
        http.finish if http.started?
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end

      def reset_after_fork
        return if @pid == Process.pid

        # The sockets belong to the parent process: forget them without closing them.
        @idle = {}
        @pid = Process.pid
      end

      def new_session(uri)
        factory = @http_client
        http = factory ? factory.call(uri) : Net::HTTP.new(uri.hostname.to_s, uri.port)
        unless http.is_a?(Net::HTTP)
          raise ConfigurationError, "http_client must return a Net::HTTP instance, got #{http.class}."
        end

        http.use_ssl = true if uri.scheme == "https" && !http.use_ssl?
        http
      end

      def configure(http, timeout)
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        http.ssl_timeout = timeout if http.use_ssl?
        # The SDK decides about retries (docs/DESIGN.md section 7), net/http never does.
        http.max_retries = 0
      end

      def pool_key(uri)
        "#{uri.scheme}://#{uri.host}:#{uri.port}"
      end
    end
  end
end
