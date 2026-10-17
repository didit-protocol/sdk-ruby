# frozen_string_literal: true

require "json"
require "openssl"
require "uri"

# A stub Didit Authentication issuer for spec/authentication.
#
# Signing keys are generated at test time and tokens are signed here; the issuer
# is a WebMock stub, so nothing touches the network. Every id, token and secret
# below is synthetic.
module AuthenticationHelper
  ISSUER = "https://acme-0a1b2c3d4e5f60718293a4b5c6d7e8f9.auth.didit.me"
  APPLICATION_ID = "6f1c2d3e-0000-4000-8000-00000000a001"
  IDENTITY_ID = "6f1c2d3e-0000-4000-8000-00000000b001"
  SESSION_ID = "6f1c2d3e-0000-4000-8000-00000000c001"
  STEP_UP_ID = "6f1c2d3e-0000-4000-8000-00000000d001"
  ACCESS_TOKEN = "synthetic-access-token-0001"
  REFRESH_TOKEN = "synthetic-refresh-token-0001"
  CODE = "synthetic-authorization-code-0001"
  CODE_VERIFIER = "synthetic-code-verifier-000000000000000000000001"
  REDIRECT_URI = "https://app.example.com/callback"
  NONCE = "synthetic-nonce-0001"
  NOW = 1_800_000_000
  DISCOVERY = "/.well-known/openid-configuration"
  JWKS = "/.well-known/jwks.json"
  # Pass as a claim override to leave the claim out.
  REMOVE = Object.new.tap { |remove| def remove.inspect = "REMOVE" }.freeze

  TOKEN_RESPONSE = {
    "access_token" => "synthetic.access.jwt",
    "id_token" => "synthetic.id.jwt",
    "refresh_token" => "synthetic-refresh-token-0002",
    "token_type" => "Bearer",
    "expires_in" => 300,
    "session_id" => SESSION_ID
  }.freeze

  module_function

  def b64url(bytes)
    [bytes].pack("m0").tr("+/", "-_").delete("=")
  end

  def segment(value)
    b64url(JSON.generate(value))
  end

  # A token with any header and signature bytes, for the rejection specs.
  def unsigned_token(header, claims, signature = "")
    "#{segment(header)}.#{segment(claims)}.#{b64url(signature)}"
  end

  def with_overrides(base, overrides)
    base.merge(overrides.transform_keys(&:to_s)).reject { |_, value| value.equal?(REMOVE) }
  end

  # The claims of a person's access token.
  def access_claims(now: NOW, **overrides)
    with_overrides(
      {
        "iss" => ISSUER, "aud" => APPLICATION_ID, "sub" => IDENTITY_ID, "sid" => SESSION_ID,
        "jti" => "synthetic-jti-0001", "iat" => now, "exp" => now + 300, "vendor_data" => "user-42",
        "org" => { "id" => "6f1c2d3e-0000-4000-8000-00000000e001", "role" => "admin" },
        "verified" => { "level" => "full_id", "over_18" => true, "country" => "ES" },
        "amr" => ["passkey"], "act" => nil, "client_id" => APPLICATION_ID
      },
      overrides
    )
  end

  # The claims of an ID token: no client_id, plus profile claims.
  def id_claims(now: NOW, **overrides)
    with_overrides(
      {
        "iss" => ISSUER, "aud" => APPLICATION_ID, "sub" => IDENTITY_ID, "sid" => SESSION_ID,
        "jti" => "synthetic-jti-0002", "iat" => now, "exp" => now + 300, "vendor_data" => "user-42",
        "org" => nil, "verified" => {}, "amr" => ["password"], "act" => nil, "auth_time" => now - 10,
        "email_verified" => true, "email" => "person@example.com", "name" => "Synthetic Person", "nonce" => NONCE
      },
      overrides
    )
  end

  # A P-256 signing key generated at test time.
  class SigningKey
    attr_reader :kid, :private_key

    def self.generate(kid)
      new(kid, OpenSSL::PKey::EC.generate("prime256v1"))
    end

    def initialize(kid, private_key)
      @kid = kid
      @private_key = private_key
    end

    def jwk
      point = private_key.public_key.to_octet_string(:uncompressed)
      {
        "kty" => "EC", "crv" => "P-256", "x" => AuthenticationHelper.b64url(point.byteslice(1, 32)),
        "y" => AuthenticationHelper.b64url(point.byteslice(33, 32)), "kid" => kid, "use" => "sig", "alg" => "ES256"
      }
    end

    # An ES256 JWS as the Didit issuer signs it (raw R || S signature).
    def sign(claims, typ: "at+jwt", kid: self.kid, header: {})
      head = { "alg" => "ES256", "kid" => kid }
      head["typ"] = typ unless typ.nil?
      signing_input = "#{AuthenticationHelper.segment(head.merge(header))}.#{AuthenticationHelper.segment(claims)}"
      "#{signing_input}.#{AuthenticationHelper.b64url(raw_signature(signing_input))}"
    end

    def der_signature(signing_input)
      private_key.sign("SHA256", signing_input)
    end

    def raw_signature(signing_input)
      OpenSSL::ASN1.decode(der_signature(signing_input)).value.map { |n| n.value.to_s(2).rjust(32, "\x00".b) }.join
    end
  end

  # Returns the configured clock reading; advance it to move time forward.
  class FakeClock
    attr_accessor :now

    def initialize(now = NOW)
      @now = now.to_f
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  # The issuer's HTTP side as a WebMock stub: discovery and JWKS built in, other routes per spec.
  class FakeIssuer
    include WebMock::API

    attr_accessor :keys, :discovery, :metadata_cache_control
    attr_reader :requests, :issuer

    def initialize(keys, issuer: ISSUER)
      @issuer = issuer
      @keys = keys
      @metadata_cache_control = "public, max-age=300"
      @discovery = {
        "issuer" => issuer,
        "authorization_endpoint" => "#{issuer}/sign-in/",
        "token_endpoint" => "#{issuer}/token/",
        "jwks_uri" => "#{issuer}/.well-known/jwks.json",
        "response_types_supported" => ["code"],
        "id_token_signing_alg_values_supported" => ["ES256"],
        "code_challenge_methods_supported" => ["S256"]
      }
      @routes = {}
      @requests = []
      stub_request(:any, /\A#{Regexp.escape(URI(issuer).origin)}/).to_return { |request| handle(request) }
    end

    # Answers +method path+ with whatever the block returns (a WebMock response Hash).
    def route(method, path, &handler)
      @routes[[method.to_s.upcase, path]] = handler
    end

    # Answers +method path+ with +status+ and a JSON +body+ (no body when nil).
    def reply(method, path, status, body = nil, headers: {})
      route(method, path) do
        if body.nil?
          { status: status, headers: headers }
        else
          { status: status, body: JSON.generate(body),
            headers: { "Content-Type" => "application/json", "X-Request-Id" => "req_synthetic" }.merge(headers) }
        end
      end
    end

    def handle(request)
      @requests << request
      method = request.method.to_s.upcase
      path = request.uri.path
      return metadata(discovery) if method == "GET" && path == DISCOVERY && !@routes.key?([method, path])
      return metadata({ "keys" => keys.map(&:jwk) }) if method == "GET" && path == JWKS && !@routes.key?([method, path])

      handler = @routes[[method, path]]
      return handler.call(request) if handler

      { status: 404, body: '{"detail": "Not found."}', headers: { "Content-Type" => "application/json" } }
    end

    def metadata(body)
      headers = { "Content-Type" => "application/json" }
      headers["Cache-Control"] = metadata_cache_control if metadata_cache_control
      { status: 200, body: JSON.generate(body), headers: headers }
    end

    def count(path)
      requests.count { |request| request.uri.path == path }
    end

    def last(path)
      requests.reverse.find { |request| request.uri.path == path }
    end

    def paths
      requests.map { |request| request.uri.path }
    end
  end

  # The decoded form body of a WebMock request.
  def form_of(request)
    URI.decode_www_form(request.body.to_s).to_h
  end

  def pk(prefix, issuer)
    prefix + b64url(issuer)
  end
end

# Shared setup: a key, a stubbed issuer, a fake clock and a client for them.
RSpec.shared_context "with a stubbed issuer" do
  let(:key) { AuthenticationHelper::SigningKey.generate("k_synthetic_key_1") }
  let(:issuer) { AuthenticationHelper::FakeIssuer.new([key]) }
  let(:clock) { AuthenticationHelper::FakeClock.new }
  let(:auth) do
    issuer
    Didit::Authentication.new(AuthenticationHelper::ISSUER, clock: clock)
  end

  # The reason of the Didit::TokenVerificationError the block raises.
  def reason_of
    yield
    raise "expected a Didit::TokenVerificationError"
  rescue Didit::TokenVerificationError => e
    e.reason
  end

  # The error the block raises, or nil.
  def error_of
    yield
    nil
  rescue StandardError => e
    e
  end
end
