# frozen_string_literal: true

require "json"
require "jwt"
require "securerandom"
require "uri"

require_relative "authentication/types"
require_relative "authentication/base64_url"
require_relative "authentication/pkce"
require_relative "authentication/issuer"
require_relative "authentication/jws"
require_relative "authentication/key_set"
require_relative "authentication/cache"
require_relative "authentication/http"

module Didit
  # Didit Authentication for your backend (docs/DESIGN.md section 10): verify the
  # tokens your application's issuer signs and call its token, session and
  # step-up endpoints.
  #
  #   auth = Didit::Authentication.from_publishable_key("pk_live_...", client_id: APPLICATION_ID)
  #   begin
  #     claims = auth.verify_access_token(access_token)
  #   rescue Didit::TokenVerificationError => e
  #     e.reason # machine readable, for example :expired
  #   end
  #
  # Each application has its own OpenID Connect issuer (+https://<slug>.auth.didit.me+
  # or its custom domain). This class talks only to that issuer and never takes or
  # sends your Didit API key. The discovery document and the issuer's keys are
  # fetched on first use and cached; one instance per process is the intended use
  # and it is thread safe. Requests are never retried.
  class Authentication
    DEFAULT_TIMEOUT = 10
    DEFAULT_LEEWAY = 60
    DISCOVERY_PATH = "/.well-known/openid-configuration"
    JWKS_PATH = "/.well-known/jwks.json"
    SESSION_PATH = "/session/"
    STEP_UP_PATH = "/step-up/"
    # The errors that mean the issuer could not give its discovery document or keys.
    FETCH_ERRORS = [APIConnectionError, APIStatusError, APIResponseValidationError].freeze
    UNRESERVED = /[^A-Za-z0-9\-._~]/n
    DECIMAL = /\A-?[0-9]+(\.[0-9]+)?\z/
    NUMBER = /\A(-?)([0-9]+)(?:\.([0-9]+))?(?:e([-+]?[0-9]+))?\z/i

    class << self
      # The client for the issuer a +pk_live_+ or +pk_test_+ publishable key carries.
      #
      # @param publishable_key [String]
      # @return [Authentication]
      # @raise [Didit::ConfigurationError] when the key is malformed
      def from_publishable_key(publishable_key, client_id: nil, timeout: DEFAULT_TIMEOUT, leeway: DEFAULT_LEEWAY,
                               http_client: nil, clock: nil)
        new(Issuer.from_publishable_key(publishable_key),
            client_id: client_id, timeout: timeout, leeway: leeway, http_client: http_client, clock: clock)
      end

      # A new random PKCE verifier and its S256 challenge.
      #
      # @return [Pkce]
      def create_pkce
        Pkce.generate
      end

      # A new random +state+ (43 url-safe characters, 256 bits). Store it with the
      # sign-in attempt and compare it with the callback's +state+ before
      # exchanging the code.
      #
      # @return [String]
      def create_state
        SecureRandom.urlsafe_base64(32)
      end

      # A new random +nonce+ (43 url-safe characters, 256 bits). Send it with the
      # authorization request and pass it to {#verify_id_token}.
      #
      # @return [String]
      def create_nonce
        SecureRandom.urlsafe_base64(32)
      end
    end

    # @return [String] the issuer every token must name in +iss+, without a trailing slash
    attr_reader :issuer
    # @return [String, nil] the application id: sent with token requests and the default audience
    attr_reader :client_id
    # @return [Numeric] seconds allowed to open a connection, and for each read and write
    attr_reader :timeout
    # @return [Float] seconds of clock skew allowed for +exp+, +nbf+ and +iat+
    attr_reader :leeway

    # @param issuer [String] the application's issuer: +https://<slug>.auth.didit.me+,
    #   +https://<slug>.sandbox.auth.didit.me+ or its active custom domain
    # @param client_id [String, nil] the application id; when set it is sent with
    #   token requests (the issuer checks it) and is the default audience
    # @param timeout [Numeric] seconds per connection open, read and write
    # @param leeway [Numeric] seconds of clock skew allowed for +exp+, +nbf+ and +iat+
    # @param http_client [#call, nil] called with a +URI+, returns a configured, not
    #   yet started +Net::HTTP+ for its host (proxies, CA bundle). The SDK sets its
    #   timeouts and never follows redirects.
    # @param clock [#call, nil] for tests: returns the current unix time in seconds
    # @raise [Didit::ConfigurationError]
    def initialize(issuer, client_id: nil, timeout: DEFAULT_TIMEOUT, leeway: DEFAULT_LEEWAY, http_client: nil,
                   clock: nil)
      @issuer = Issuer.normalize(issuer)
      @client_id = checked_client_id(client_id)
      @timeout = checked_timeout(timeout)
      @leeway = checked_leeway(leeway)
      raise ConfigurationError, "http_client must respond to #call." unless http_client.nil? || http_client.respond_to?(:call)
      raise ConfigurationError, "clock must respond to #call." unless clock.nil? || clock.respond_to?(:call)

      @clock = clock || -> { Time.now.to_f }
      @cache = IssuerCache.new(@clock)
      @transport = Transport.new(timeout: @timeout, http_client: http_client)
      @lock = Mutex.new
    end

    # Verifies an access token offline and returns its claims.
    #
    # Checks, in order: the header (+alg+ ES256 only, so +none+, HS*, RS*, PS*,
    # EdDSA and every other algorithm are refused; +typ+ +at+jwt+), the ES256
    # signature against the issuer's published key with the token's +kid+, then
    # +iss+ (equal to the issuer), +sub+, +exp+, +nbf+ and +iat+ (with {#leeway}
    # seconds of clock skew) and, when +audience+ is given or +client_id+ is
    # configured, +aud+.
    #
    # An offline check cannot see a session revoked a moment ago: access tokens
    # expire within five minutes. Call {#get_session} when the action needs an
    # instant revocation check.
    #
    # @param token [String]
    # @param audience [String, Array<String>, nil] accepted audiences; defaults to +client_id+
    # @return [AccessTokenClaims]
    # @raise [Didit::TokenVerificationError] the token is not valid; +reason+ says why
    # @raise [Didit::APIConnectionError, Didit::APIStatusError, Didit::APIResponseValidationError]
    #   the issuer's keys could not be fetched
    def verify_access_token(token, audience: nil)
      expected = expected_audience(audience, required: false)
      AccessTokenClaims.new(verify(token, :access, expected, nil))
    end

    # Verifies an ID token and returns its claims.
    #
    # The same checks as {#verify_access_token} (+typ+ must be +JWT+ or absent,
    # never +at+jwt+), plus +aud+, which is always checked: pass +audience+ or
    # configure +client_id+. +nonce+ must equal the +nonce+ you sent with the
    # authorization request. Pass +nonce: nil+ for an ID token returned by
    # {#refresh}, which carries none: then a token that carries a nonce is refused.
    #
    # @param token [String]
    # @param nonce [String, nil]
    # @param audience [String, Array<String>, nil] defaults to +client_id+
    # @return [IdTokenClaims]
    # @raise [Didit::TokenVerificationError]
    # @raise [Didit::ConfigurationError] without an audience
    def verify_id_token(token, nonce:, audience: nil)
      expected = expected_audience(audience, required: true)
      if !nonce.nil? && !(nonce.is_a?(String) && !nonce.empty?)
        raise ConfigurationError, "nonce is empty: pass the nonce of this sign-in, or nil for an ID token from refresh."
      end

      IdTokenClaims.new(verify(token, :id, expected, nonce))
    end

    # Exchanges an authorization code for tokens (+POST token/+, form encoded).
    #
    # Check the callback's +state+ first. The code is single use and expires
    # after 60 seconds; +code_verifier+ is the PKCE verifier of this sign-in and
    # +redirect_uri+ must be exactly the one the sign-in used. Never retried.
    #
    # @return [TokenResponse]
    # @raise [Didit::BadRequestError] +invalid_grant+ for a used, expired or unknown code
    def exchange_code(code, code_verifier:, redirect_uri:)
      code = required_text(code, "code")
      code_verifier = required_text(code_verifier, "code_verifier")
      form = {
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "redirect_uri" => required_text(redirect_uri, "redirect_uri")
      }
      token_request(form, [code, code_verifier])
    end

    # Swaps a refresh token for new tokens (+POST token/+, form encoded).
    #
    # Refresh tokens are single use: replace both tokens with the result.
    # Serialise refreshes for one session (one at a time, across processes and
    # browser tabs), because presenting a refresh token that was already used
    # revokes the whole session. For the same reason this request is never
    # retried; if its outcome is unknown, sign the person in again.
    #
    # @return [TokenResponse]
    def refresh(refresh_token)
      refresh_token = required_text(refresh_token, "refresh_token")
      token_request({ "grant_type" => "refresh_token", "refresh_token" => refresh_token }, [refresh_token])
    end

    # The live session behind +access_token+ (+GET session/+).
    #
    # The instant revocation check: unlike {#verify_access_token} it fails
    # (+Didit::AuthenticationError+, HTTP 401) as soon as the session is revoked,
    # expired or idle, or the token was replaced by a refresh. Agent access
    # tokens are refused here.
    #
    # @return [Session]
    def get_session(access_token)
      Session.new(send_object(bearer_call("GET", issuer_uri(SESSION_PATH), access_token)))
    end

    # Signs the person out: revokes the session behind +access_token+ (+DELETE session/+).
    #
    # @return [nil]
    def revoke_session(access_token)
      call = bearer_call("DELETE", issuer_uri(SESSION_PATH), access_token)
      @transport.read(call, @transport.perform(call))
      nil
    end

    # Asks whether the person must verify before a sensitive action (+POST step-up/+).
    #
    # +action+ is "payout" (with +amount+ and an optional three-letter
    # +currency+), "bank" or "contact". +return_to+ is where the person comes back
    # after verifying and must be one of the application's redirect URIs; the
    # issuer currently requires it and answers HTTP 400 without it.
    #
    # +required == false+ means no rule applies and the action may go ahead.
    # Otherwise send the person to +verification_url+; they come back to
    # +return_to+ with +step_up=<id>&status=approved+, which proves nothing: call
    # {#retrieve_step_up} and act only on status "approved".
    #
    # @param amount [String, Integer, Float, BigDecimal, nil] sent as a decimal string
    # @return [StepUp]
    def create_step_up(access_token, action:, amount: nil, currency: nil, return_to: nil)
      body = { "action" => required_text(action, "action") } # : Hash[String, untyped]
      body["amount"] = amount_text(amount) unless amount.nil?
      body["currency"] = optional_text(currency, "currency") unless currency.nil?
      body["return_to"] = optional_text(return_to, "return_to") unless return_to.nil?
      StepUp.new(send_object(bearer_call("POST", issuer_uri(STEP_UP_PATH), access_token, json: body)))
    end

    # Reads a step-up (+GET step-up/{id}/+) with a token of the session that asked
    # for it. Act only when its status is "approved" ({StepUp#approved?});
    # "pending", "review", "declined", "expired" and "superseded" all mean no.
    #
    # @return [StepUp]
    # @raise [Didit::ConfigurationError] when +step_up_id+ is empty, "." or ".."
    def retrieve_step_up(access_token, step_up_id)
      unless step_up_id.is_a?(String) && !step_up_id.empty? && !%w[. ..].include?(step_up_id)
        raise ConfigurationError, "step_up_id must be a non-empty string other than \".\" and \"..\"."
      end

      path = "#{STEP_UP_PATH}#{step_up_id.b.gsub(UNRESERVED) { |c| format("%%%02X", c.ord) }}/"
      StepUp.new(send_object(bearer_call("GET", issuer_uri(path), access_token)))
    end

    # The issuer's discovery document, fetched and cached like the keys. For debugging.
    #
    # @return [Hash] frozen
    def discovery
      current_discovery.document
    end

    # The issuer's JSON Web Key Set, fetched and cached as for token verification. For debugging.
    #
    # @return [Hash] frozen
    def jwks
      key_set(nil).document
    end

    def inspect
      "#<#{self.class.name} issuer=#{issuer.inspect} client_id=#{client_id.inspect}>"
    end
    alias to_s inspect

    private

    # Token checks ------------------------------------------------------------

    def verify(token, kind, audience, nonce)
      parsed = Jws.parse(token, kind)
      key = key_set(parsed.kid)[parsed.kid]
      unless key
        raise TokenVerificationError.new(
          :unknown_key, "The issuer publishes no ES256 (P-256) key with the token's key id (kid)."
        )
      end

      Jws.verify_signature(parsed, key)
      Jws.check_claims(parsed.claims, kind: kind, issuer: issuer, audience: audience, nonce: nonce,
                                      leeway: leeway, now: @clock.call.to_f)
      parsed.claims
    end

    def expected_audience(audience, required:)
      if audience.nil?
        return [client_id] if client_id
        return nil unless required

        raise ConfigurationError,
              "verify_id_token needs the audience: pass audience: <application id>, or client_id: <application id> " \
              "to Didit::Authentication."
      end
      values = audience.is_a?(Array) ? audience : [audience]
      if values.empty? || !values.all? { |value| value.is_a?(String) && !value.empty? }
        raise ConfigurationError, "audience must be a non-empty string or an array of them."
      end

      values
    end

    # Discovery and keys ------------------------------------------------------

    def current_discovery
      @cache.discovery || @lock.synchronize { discovery_locked }
    end

    def discovery_locked
      cached = @cache.discovery
      return cached if cached

      call = Transport::Call.new("GET", issuer_uri(DISCOVERY_PATH))
      response = @transport.perform(call)
      @cache.store_discovery(parse_discovery(call, response), response.headers)
    end

    # The fresh key set that should hold +kid+, fetching it when needed (at most
    # once a minute for an unknown kid). A nil +kid+ asks for any fresh key set.
    def key_set(kid)
      cached = kid ? @cache.key_set_with(kid) : @cache.key_set
      cached || @lock.synchronize { key_set_locked(kid) }
    end

    def key_set_locked(kid)
      raise keys_unavailable if @cache.key_set_unavailable?

      cached = @cache.key_set
      return cached if cached && !@cache.needs_key_set_fetch?(kid)

      begin
        call = Transport::Call.new("GET", URI(discovery_locked.jwks_uri))
        response = @transport.perform(call)
        data = @transport.read(call, response)
        parsed = KeySet.parse(data)
        raise @transport.validation_error(call, response, 'The issuer\'s JWKS is not a key set ({"keys": [...]}).') unless parsed

        @cache.store_key_set(parsed, response.headers)
      rescue *FETCH_ERRORS
        # Counted only when the issuer failed, not for a configuration error, which is raised every time.
        @cache.key_set_fetch_failed
        raise
      end
    end

    def keys_unavailable
      url = @cache.discovery&.jwks_uri || "#{issuer}#{JWKS_PATH}"
      APIConnectionError.new(
        "The issuer's keys could not be fetched less than a minute ago; the next attempt is made once that " \
        "minute has passed.",
        http_method: "GET", url: Internal::Util.display_url(url)
      )
    end

    def parse_discovery(call, response)
      data = @transport.read_object(call, response)
      found = data["issuer"]
      raise @transport.validation_error(call, response, "The discovery document names no issuer.") unless found.is_a?(String)
      if found != issuer
        raise ConfigurationError,
              "The discovery document at #{call.display_url} names the issuer #{found.inspect}, not #{issuer.inspect}. " \
              "Configure Didit::Authentication with #{found.inspect} (an application's issuer changes when its " \
              "custom domain is activated)."
      end

      Discovery.new(
        issuer: found, document: data,
        token_endpoint: issuer_endpoint(call, response, data, "token_endpoint"),
        jwks_uri: issuer_endpoint(call, response, data, "jwks_uri")
      )
    end

    # A discovery endpoint, which must be on the issuer's own origin: codes and
    # refresh tokens go to the token endpoint and the keys decide which tokens are
    # trusted, so neither may move to plain http or to another host.
    def issuer_endpoint(call, response, data, name)
      value = data[name]
      uri = endpoint_uri(value)
      raise @transport.validation_error(call, response, "The discovery document has no valid #{name}.") unless uri

      issuer_origin = Internal::Util.origin(issuer)
      return value if Internal::Util.origin(uri) == issuer_origin && value.is_a?(String)

      problem = uri.scheme == "http" && issuer_origin.start_with?("https:") ? "does not use https" : "is not on the issuer's origin #{issuer_origin}"
      raise @transport.validation_error(call, response, "The discovery document's #{name} #{value.inspect} #{problem}.")
    end

    def endpoint_uri(value)
      return nil unless value.is_a?(String)

      uri = URI.parse(value)
      uri if uri.is_a?(URI::HTTP) && !uri.hostname.to_s.empty? && uri.userinfo.nil?
    rescue URI::Error
      nil
    end

    # Requests ----------------------------------------------------------------

    def token_request(form, secrets)
      form["client_id"] = client_id if client_id
      call = Transport::Call.new("POST", URI(current_discovery.token_endpoint), form: form, secrets: secrets)
      TokenResponse.new(send_object(call))
    end

    def bearer_call(http_method, uri, access_token, json: nil)
      token = required_text(access_token, "access_token")
      raise ConfigurationError, "access_token contains invalid characters." if token.match?(/[\x00-\x20\x7f]/)

      Transport::Call.new(http_method, uri, bearer: token, json: json, secrets: [token])
    end

    def send_object(call)
      @transport.read_object(call, @transport.perform(call))
    end

    def issuer_uri(path)
      URI("#{issuer}#{path}")
    end

    # Arguments ---------------------------------------------------------------

    def required_text(value, name)
      text = value.is_a?(String) ? value.strip : ""
      raise ConfigurationError, "#{name} is empty." if text.empty?

      text
    end

    def optional_text(value, name)
      raise ConfigurationError, "#{name} must be a string." unless value.is_a?(String)

      value
    end

    # A money amount as a plain decimal string ("1500.00"), never in exponent form.
    def amount_text(amount)
      if amount.is_a?(String)
        text = amount.strip
        return text if DECIMAL.match?(text)

        raise ConfigurationError, "amount must be a decimal number such as \"1500.00\", got #{amount.inspect}."
      end
      return amount.to_s if amount.is_a?(Integer)

      text = plain_decimal(amount.to_s) if amount.is_a?(Numeric) && !amount.is_a?(Complex)
      return text if text

      raise ConfigurationError, "amount must be a finite decimal String, Integer, Float or BigDecimal, got #{amount.inspect}."
    end

    # "1.5e-05" => "0.000015", "0.15e4" => "1500"; nil for anything else (NaN, Infinity, "3/2").
    def plain_decimal(text)
      match = NUMBER.match(text)
      return nil unless match

      sign, whole, fraction, exponent = match.captures
      return text unless exponent

      digits = "#{whole}#{fraction}"
      point = whole.to_s.length + exponent.to_i
      value = if point <= 0
                "0.#{"0" * -point}#{digits}"
              elsif point >= digits.length
                digits + ("0" * (point - digits.length))
              else
                "#{digits[0, point]}.#{digits[point..]}"
              end
      value = value.sub(/\A0+(?=\d)/, "")
      value = value.sub(/\.?0+\z/, "") if value.include?(".")
      "#{sign}#{value}"
    end

    # Options -----------------------------------------------------------------

    def checked_client_id(client_id)
      return nil if client_id.nil?
      if client_id.is_a?(String) && !client_id.strip.empty?
        return client_id.strip
      end

      raise ConfigurationError, "client_id is empty: pass your application id or leave it out."
    end

    def checked_timeout(timeout)
      return timeout if timeout.is_a?(Numeric) && !timeout.is_a?(Complex) && timeout.positive? && timeout.finite?

      raise ConfigurationError, "timeout must be a positive number of seconds."
    end

    def checked_leeway(leeway)
      if leeway.is_a?(Integer) || leeway.is_a?(Float)
        value = leeway.to_f
        return value if value.finite? && value >= 0
      end

      raise ConfigurationError, "leeway must be 0 or more seconds."
    end
  end
end
