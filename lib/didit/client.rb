# frozen_string_literal: true

require "json"
require "set"

module Didit
  # The Didit API client (docs/DESIGN.md section 6). Thread safe: create one per process
  # and share it.
  #
  #   didit = Didit::Client.new                       # reads DIDIT_API_KEY
  #   didit = Didit::Client.new(api_key: "...", organization_id: "...", application_id: "...")
  #   session = didit.sessions.create(workflow_id: "...", vendor_data: "user-42")
  class Client
    include Resources::ClientMethods

    DEFAULT_BASE_URL = Internal::Config::DEFAULT_BASE_URL
    DEFAULT_ACCOUNT_BASE_URL = Internal::Config::DEFAULT_ACCOUNT_BASE_URL
    DEFAULT_TIMEOUT = Internal::Config::DEFAULT_TIMEOUT
    DEFAULT_MAX_RETRIES = Internal::Config::DEFAULT_MAX_RETRIES

    @deprecation_lock = Mutex.new
    @deprecation_warned = Set.new

    class << self
      # @api private
      attr_reader :deprecation_lock, :deprecation_warned
    end

    # @param api_key [String, nil] defaults to the DIDIT_API_KEY environment variable
    # @param organization_id [String, nil] defaults to DIDIT_ORGANIZATION_ID; needed by application-scoped methods
    # @param application_id [String, nil] defaults to DIDIT_APPLICATION_ID; needed by application-scoped methods
    # @param base_url [String] the verification API
    # @param account_base_url [String] the account API (+didit.account+)
    # @param account_token [String, nil] the Bearer token of +didit.account+ methods, from +didit.account.login+
    # @param timeout [Numeric] seconds per attempt (connect, write and read each)
    # @param max_retries [Integer] retries after the first attempt
    # @param default_headers [Hash{String => String}] sent with every request
    # @param logger [#debug, nil] receives debug lines; DIDIT_LOG=debug prints them to stderr instead
    # @param http_client [#call, nil] returns a configured, not yet started +Net::HTTP+ for a URI
    #   (proxies, CA bundle, ...); the SDK sets the timeouts and owns the connection
    def initialize(api_key: nil, organization_id: nil, application_id: nil, base_url: nil,
                   account_base_url: nil, account_token: nil, timeout: DEFAULT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, default_headers: {}, logger: nil, http_client: nil)
      config = Internal::Config.new(
        api_key: api_key || ENV.fetch("DIDIT_API_KEY", nil),
        organization_id: organization_id || ENV.fetch("DIDIT_ORGANIZATION_ID", nil),
        application_id: application_id || ENV.fetch("DIDIT_APPLICATION_ID", nil),
        base_url: base_url, account_base_url: account_base_url, account_token: account_token, timeout: timeout,
        max_retries: max_retries, default_headers: default_headers, logger: logger, http_client: http_client
      )
      setup(config, Internal::Transport.new(http_client: config.http_client), raw: false)
    end

    # @return [String]
    def base_url = @config.base_url
    # @return [String]
    def account_base_url = @config.account_base_url
    # @return [String, nil]
    def organization_id = @config.organization_id
    # @return [String, nil]
    def application_id = @config.application_id
    # @return [Float]
    def timeout = @config.timeout
    # @return [Integer]
    def max_retries = @config.max_retries

    # A client with some options changed. It shares this client's connections.
    # Passing nil clears an id or a token.
    #
    #   didit.with_options(timeout: 5, max_retries: 0).sessions.retrieve(id)
    #   account = didit.with_options(account_token: login.access_token)
    #
    # @return [Didit::Client]
    def with_options(**changes)
      allowed = Internal::Config::FIELDS - [:http_client]
      unknown = changes.keys - allowed
      unless unknown.empty?
        raise ConfigurationError, "Unknown options #{unknown.map(&:inspect).join(', ')}; use " \
                                  "#{allowed.map(&:inspect).join(', ')}."
      end
      copy(@config.merge(changes), raw: @raw)
    end

    # A client whose methods return the {Didit::RawResponse} (status, headers, request id)
    # instead of the parsed result; +#parse+ gives the result.
    #
    # @return [Didit::Client]
    def with_raw_response
      copy(@config, raw: true)
    end

    # Whether methods return {Didit::RawResponse}.
    def raw_response?
      @raw
    end

    # Closes the idle connections (they also close by themselves).
    def close
      @transport.close
    end

    def inspect
      "#<Didit::Client base_url=#{base_url.inspect} organization_id=#{organization_id.inspect} " \
        "application_id=#{application_id.inspect} api_key=#{@config.api_key ? '[set]' : 'nil'}>"
    end
    alias to_s inspect

    # Sends a request to any API path; the generated resource methods call this.
    #
    # @param http_method [Symbol] :get, :post, :put, :patch or :delete
    # @param path [String] a path with +{name}+ placeholders filled from +path_params+
    # @param response [Object] the type of the result: a Didit::Model subclass, +[:array, type]+,
    #   +:binary+, a Hash of types by status, or nil for no content
    # @param page [Object] the item type of a paginated list (returns a {Didit::Page})
    # @return [Object] the typed result, or a {Didit::RawResponse} from {#with_raw_response}
    def request(http_method, path, path_params: {}, query: nil, body: nil, encoding: :json, file_fields: [],
                headers: {}, auth: :api_key, api: :verification, scope: nil, response: nil, page: nil,
                accept: "application/json", request_options: nil, &block)
      opts = Internal::Request.options(@config, request_options)
      prepared = Internal::Request.prepare(
        @config, http_method, path, opts, path_params: path_params, query: query, body: body,
        encoding: encoding, file_fields: file_fields, headers: headers, auth: auth, api: api, scope: scope,
        accept: accept
      )
      stream = response == :binary ? block : nil
      result = Internal::Request.perform(@config, @transport, prepared, &stream)
      parser = -> { parse(prepared, result.response, response, page) }
      return parser.call unless @raw

      raw = result.response
      RawResponse.new(status: raw.status, headers: raw.headers, body: raw.body, retries_taken: result.retries_taken,
                      elapsed: result.elapsed, parser: parser)
    end

    # Fetches a page's +next+ link with the request options of the first page.
    # @api private
    def fetch_page(prepared, uri, item, seen)
      next_request = prepared.dup
      next_request.uri = uri
      next_request.http_method = :get
      next_request.body = nil
      result = Internal::Request.perform(@config, @transport, next_request)
      response = check_status(next_request, result.response)
      Page.new(client: self, prepared: next_request, item: item, data: parse_json(next_request, response),
               seen: seen)
    end

    # Warns once per process that a deprecated method was called (Ruby's :deprecated warning category).
    # @api private
    def deprecated(name, note)
      first = Client.deprecation_lock.synchronize { Client.deprecation_warned.add?(name) }
      Kernel.warn("Didit: #{name} is deprecated. #{note}", category: :deprecated) if first
      nil
    end

    protected

    attr_reader :config, :transport

    def setup(config, transport, raw:)
      @config = config
      @transport = transport
      @raw = raw
      self
    end

    private

    def copy(config, raw:)
      transport = config.http_client.equal?(@config.http_client) ? @transport : Internal::Transport.new(http_client: config.http_client)
      Client.allocate.send(:setup, config, transport, raw: raw)
    end

    def parse(prepared, response, type, page)
      check_status(prepared, response)
      return Page.new(client: self, prepared: prepared, item: page, data: parse_json(prepared, response)) if page
      return response.body if type == :binary
      return nil if type.nil?

      type = type.fetch(response.status) { type.values.first } if type.is_a?(Hash)
      return nil if response.status == 204 || response.body.nil? || response.body.empty?

      Model.coerce(parse_json(prepared, response), type)
    end

    def check_status(prepared, response)
      return response if response.status.between?(200, 299)

      raise Internal::Errors.status_error(status: response.status, headers: response.headers,
                                          raw_body: response.body, redact: prepared.redact)
    end

    def parse_json(prepared, response)
      text = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
      raise JSON::ParserError, "invalid UTF-8" unless text.valid_encoding?

      JSON.parse(text)
    rescue JSON::ParserError
      raise APIResponseValidationError.new(
        "Expected a JSON response from #{prepared.http_method.to_s.upcase} #{prepared.uri.path}, got " \
        "#{response.headers['content-type'] || 'no content type'}.",
        status: response.status, headers: response.headers,
        body: Internal::Util.redact(text.scrub, prepared.redact), request_id: Internal::Util.request_id(response.headers)
      )
    end
  end
end
