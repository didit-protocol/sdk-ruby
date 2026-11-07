# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "discovery and keys" do
    include AuthenticationHelper

    include_context "with a stubbed issuer"

    def fresh_token(signing_key = key)
      signing_key.sign(access_claims(now: clock.now.to_i))
    end

    it "fetches the discovery document and keys lazily and caches them" do
      expect(issuer.requests).to be_empty
      2.times { auth.verify_access_token(fresh_token) }
      clock.advance(299)
      auth.verify_access_token(fresh_token)
      expect([issuer.count(DISCOVERY), issuer.count(JWKS)]).to eq([1, 1])

      clock.advance(2)
      auth.verify_access_token(fresh_token)
      expect([issuer.count(DISCOVERY), issuer.count(JWKS)]).to eq([2, 2])
    end

    it "sends the SDK headers and never an Authorization header or API key" do
      auth.verify_access_token(fresh_token)
      request = issuer.last(JWKS)

      expect(request.headers["Accept"]).to eq("application/json")
      expect(request.headers["User-Agent"]).to eq(Didit::Internal::Util.user_agent)
      expect(request.headers["X-Didit-Client"]).to eq("ruby/#{Didit::VERSION}")
      expect(request.headers.keys.map(&:downcase)).not_to include("authorization", "x-api-key")
    end

    {
      "public, max-age=10" => 60, nil => 300, "public, max-age=3600" => 3600, "no-store" => 60, "no-cache" => 60
    }.each do |cache_control, fresh_for|
      it "keeps the key set #{fresh_for} s for Cache-Control #{cache_control.inspect}" do
        issuer.metadata_cache_control = cache_control
        auth.verify_access_token(fresh_token)
        clock.advance(fresh_for - 1)
        auth.verify_access_token(fresh_token)
        expect(issuer.count(JWKS)).to eq(1)

        clock.advance(1)
        auth.verify_access_token(fresh_token)
        expect(issuer.count(JWKS)).to eq(2)
      end
    end

    it "honours the Age header" do
      issuer.route(:get, JWKS) do
        { status: 200, body: JSON.generate({ "keys" => [key.jwk] }),
          headers: { "Cache-Control" => "max-age=300", "Age" => "200" } }
      end
      auth.verify_access_token(fresh_token)
      clock.advance(99)
      auth.verify_access_token(fresh_token)
      expect(issuer.count(JWKS)).to eq(1)
      clock.advance(1)
      auth.verify_access_token(fresh_token)
      expect(issuer.count(JWKS)).to eq(2)
    end

    describe "an unknown kid" do
      let(:rotated) { AuthenticationHelper::SigningKey.generate("k_synthetic_key_2") }
      let(:stranger) { AuthenticationHelper::SigningKey.generate("k_never_published") }

      it "refetches at most once a minute, counting the last fetch" do
        auth.verify_access_token(fresh_token)
        clock.advance(1)
        expect(reason_of { auth.verify_access_token(fresh_token(stranger)) }).to eq(:unknown_key)
        expect(issuer.count(JWKS)).to eq(1)

        clock.advance(59)
        expect(reason_of { auth.verify_access_token(fresh_token(stranger)) }).to eq(:unknown_key)
        expect(issuer.count(JWKS)).to eq(2)

        other = AuthenticationHelper::SigningKey.generate("k_other_stranger")
        clock.advance(30)
        expect(reason_of { auth.verify_access_token(fresh_token(other)) }).to eq(:unknown_key)
        expect(issuer.count(JWKS)).to eq(2)

        clock.advance(30)
        expect(reason_of { auth.verify_access_token(fresh_token(other)) }).to eq(:unknown_key)
        expect(issuer.count(JWKS)).to eq(3)
        # Known keys keep verifying from the cache meanwhile.
        auth.verify_access_token(fresh_token)
        expect(issuer.count(JWKS)).to eq(3)
      end

      it "picks up a rotated key with the refetch" do
        auth.verify_access_token(fresh_token)
        clock.advance(10)
        expect(reason_of { auth.verify_access_token(fresh_token(rotated)) }).to eq(:unknown_key)
        issuer.keys = [rotated]
        clock.advance(50)

        expect(auth.verify_access_token(fresh_token(rotated)).sub).to eq(IDENTITY_ID)
        expect(issuer.count(JWKS)).to eq(2)
        # The retired key is gone from the new key set.
        clock.advance(60)
        expect(reason_of { auth.verify_access_token(fresh_token) }).to eq(:unknown_key)
      end
    end

    describe "published keys that cannot verify ES256" do
      [
        { "kty" => "RSA" }, { "crv" => "P-384" }, { "alg" => "ES384" }, { "use" => "enc" }, { "use" => nil },
        { "x" => AuthenticationHelper.b64url("\x01" * 31) }, { "y" => 42 }, { "x" => "AAAA=" },
        { "x" => AuthenticationHelper.b64url("\x00" * 32), "y" => AuthenticationHelper.b64url("\x00" * 32) }
      ].each do |change|
        it "treats #{change.inspect} as an unknown key" do
          jwk = key.jwk.merge(change)
          issuer.route(:get, JWKS) { { status: 200, body: JSON.generate({ "keys" => [jwk] }) } }
          expect(reason_of { auth.verify_access_token(fresh_token) }).to eq(:unknown_key)
        end
      end

      it "skips entries without a usable kid and takes the first usable key per kid" do
        impostor = AuthenticationHelper::SigningKey.generate(key.kid)
        keys = [{ "kty" => "EC" }, "junk", key.jwk.merge("kid" => ""), key.jwk.merge("kty" => "RSA"), key.jwk,
                impostor.jwk]
        issuer.route(:get, JWKS) { { status: 200, body: JSON.generate({ "keys" => keys }) } }
        expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
      end
    end

    it "reads the keys from the discovered jwks_uri" do
      issuer.discovery["jwks_uri"] = "#{ISSUER}/keys/custom.json"
      issuer.route(:get, "/keys/custom.json") { { status: 200, body: JSON.generate({ "keys" => [key.jwk] }) } }

      expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
      expect([issuer.count("/keys/custom.json"), issuer.count(JWKS)]).to eq([1, 0])
    end

    describe "discovery validation" do
      it "refuses a document that names another issuer, and fetches it again only after a minute" do
        issuer.discovery["issuer"] = "https://login.example.com"
        3.times do
          expect { auth.verify_access_token(fresh_token) }
            .to raise_error(Didit::ConfigurationError, %r{names the issuer "https://login\.example\.com"})
        end
        expect(issuer.count(DISCOVERY)).to eq(1)
        clock.advance(61)
        expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::ConfigurationError)
        expect(issuer.count(DISCOVERY)).to eq(2)
        expect(issuer.count(JWKS)).to eq(0)
      end

      it "refuses the configured issuer only once a minute across threads" do
        issuer.discovery["issuer"] = "https://login.example.com"
        auth
        errors = Array.new(8) { Thread.new { error_of { auth.verify_access_token(fresh_token) } } }.map(&:value)
        expect(errors).to all(be_a(Didit::ConfigurationError))
        expect(issuer.count(DISCOVERY)).to eq(1)
      end

      it "picks up the right document once the minute has passed" do
        issuer.discovery["issuer"] = "https://login.example.com"
        expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::ConfigurationError)
        issuer.discovery["issuer"] = ISSUER
        clock.advance(61)
        expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
      end

      it "follows advice that names the issuer with a trailing slash" do
        issuer.discovery["issuer"] = "#{ISSUER}/"
        slashed = key.sign(access_claims(iss: "#{ISSUER}/"))
        # The document's issuer, slash included, is what tokens must carry.
        expect(auth.verify_access_token(slashed).iss).to eq("#{ISSUER}/")
        expect(reason_of { auth.verify_access_token(fresh_token) }).to eq(:invalid_issuer)
        configured = described_class.new("#{ISSUER}/", clock: clock)
        expect(configured.issuer).to eq(ISSUER)
        expect(configured.verify_access_token(slashed).iss).to eq("#{ISSUER}/")
      end

      it "refuses a document without an issuer" do
        issuer.discovery.delete("issuer")
        expect { auth.verify_access_token(fresh_token) }
          .to raise_error(Didit::APIResponseValidationError, /names no issuer/)
      end

      host = URI(ISSUER).host
      {
        ["token_endpoint", "http://#{host}/token/"] => /does not use https/,
        ["token_endpoint", "https://evil.example/steal"] => /not on the issuer's origin/,
        ["token_endpoint", "#{ISSUER}:8443/token/"] => /not on the issuer's origin/,
        ["token_endpoint", "https://user:pass@#{host}/token/"] => /no valid token_endpoint/,
        ["token_endpoint", nil] => /no valid token_endpoint/,
        ["token_endpoint", 42] => /no valid token_endpoint/,
        ["jwks_uri", "http://#{host}/.well-known/jwks.json"] => /does not use https/,
        ["jwks_uri", "https://keys.example.com/jwks.json"] => /not on the issuer's origin/,
        ["jwks_uri", "https://[::1"] => /no valid jwks_uri/,
        ["jwks_uri", "/.well-known/jwks.json"] => /no valid jwks_uri/
      }.each do |(name, value), message|
        it "refuses #{name} #{value.inspect} without sending anything there" do
          if value.nil?
            issuer.discovery.delete(name)
          else
            issuer.discovery[name] = value
          end
          issuer.reply(:post, "/token/", 200, TOKEN_RESPONSE)

          expect { auth.refresh(REFRESH_TOKEN) }.to raise_error(Didit::APIResponseValidationError, message)
          expect(issuer.paths).to eq([DISCOVERY])
        end
      end

      it "accepts endpoints on the issuer's origin written in another case or with the default port" do
        issuer.discovery["token_endpoint"] = "https://#{URI(ISSUER).host.upcase}:443/token/"
        issuer.reply(:post, "/token/", 200, TOKEN_RESPONSE)
        expect(auth.refresh(REFRESH_TOKEN).token_type).to eq("Bearer")
      end

      [
        { status: 200, body: "<html>", headers: { "Content-Type" => "text/html" } },
        { status: 200, body: '["not", "an", "object"]' },
        { status: 200, body: "null" },
        { status: 204 }
      ].each do |response|
        it "refuses a discovery response #{response.inspect}" do
          issuer.route(:get, DISCOVERY) { response }
          expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::APIResponseValidationError)
        end
      end

      [{ "keys" => "none" }, [], { "keys" => {} }, "keys"].each do |body|
        it "refuses a JWKS #{body.inspect}" do
          issuer.route(:get, JWKS) { { status: 200, body: JSON.generate(body) } }
          expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::APIResponseValidationError)
        end
      end

      it "passes on an HTTP error from the issuer" do
        issuer.route(:get, DISCOVERY) { { status: 503, body: "upstream unavailable" } }
        error = error_of { auth.verify_access_token(fresh_token) }

        expect(error).to be_a(Didit::InternalServerError)
        expect([error.status, error.message]).to eq([503, "HTTP 503: upstream unavailable"])
      end
    end

    describe "failed fetches" do
      let(:keys_path) { "/keys/flaky.json" }
      let(:up) { [false] }

      before do
        issuer.discovery["jwks_uri"] = "#{ISSUER}#{keys_path}"
        state = up
        jwk = key.jwk
        issuer.route(:get, keys_path) do
          if state.first
            { status: 200, body: JSON.generate({ "keys" => [jwk] }) }
          else
            { status: 500, body: '{"detail": "down"}' }
          end
        end
      end

      it "fail fast for a minute, as a connection problem, then recover" do
        expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::InternalServerError)
        10.times do |index|
          clock.advance(1)
          stranger = AuthenticationHelper::SigningKey.generate("k_random_#{index}")
          error = error_of { auth.verify_access_token(fresh_token(stranger)) }
          expect(error).to be_a(Didit::APIConnectionError)
          expect(error.message).to include("less than a minute ago")
          expect([error.http_method, error.url]).to eq(["GET", "#{ISSUER}#{keys_path}"])
        end
        expect(issuer.count(keys_path)).to eq(1)

        clock.advance(50)
        up[0] = true
        expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
        expect(issuer.count(keys_path)).to eq(2)
      end

      it "consume the refetch slot of an unknown kid while a key set is fresh" do
        up[0] = true
        auth.verify_access_token(fresh_token)
        clock.advance(60)
        up[0] = false
        newcomer = AuthenticationHelper::SigningKey.generate("k_new")
        expect { auth.verify_access_token(fresh_token(newcomer)) }.to raise_error(Didit::InternalServerError)

        clock.advance(1)
        newer = AuthenticationHelper::SigningKey.generate("k_newer")
        expect(reason_of { auth.verify_access_token(fresh_token(newer)) }).to eq(:unknown_key)
        expect(issuer.count(keys_path)).to eq(2)
        # Known keys keep verifying from the cache, which the failure did not touch.
        expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
      end

      it "include a failed discovery" do
        discovery = issuer.discovery
        issuer.route(:get, DISCOVERY) { { status: 200, body: "null" } }
        expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::APIResponseValidationError)
        expect { auth.verify_access_token(fresh_token) }.to raise_error(Didit::APIConnectionError, /less than a minute/)
        expect(issuer.count(DISCOVERY)).to eq(1)

        issuer.route(:get, DISCOVERY) { { status: 200, body: JSON.generate(discovery) } }
        up[0] = true
        clock.advance(60)
        expect(auth.verify_access_token(fresh_token).sub).to eq(IDENTITY_ID)
      end
    end

    it "exposes the cached documents, frozen" do
      expect(auth.discovery["issuer"]).to eq(ISSUER)
      expect(auth.jwks["keys"].first["kid"]).to eq(key.kid)
      expect(auth.discovery).to be_frozen
      expect(auth.jwks["keys"].first).to be_frozen
      expect([issuer.count(DISCOVERY), issuer.count(JWKS)]).to eq([1, 1])
    end

    it "fetches the keys once for concurrent threads" do
      issuer.route(:get, JWKS) do
        sleep 0.05
        { status: 200, body: JSON.generate({ "keys" => [key.jwk] }) }
      end
      tokens = Array.new(8) { fresh_token }
      subjects = tokens.map { |token| Thread.new { auth.verify_access_token(token).sub } }.map(&:value)

      expect(subjects).to eq([IDENTITY_ID] * 8)
      expect([issuer.count(DISCOVERY), issuer.count(JWKS)]).to eq([1, 1])
    end
  end

  RSpec.describe Didit::Authentication::IssuerCache, ".cache_seconds" do
    {
      {} => 300,
      { "cache-control" => "public, max-age=300" } => 300,
      { "cache-control" => "max-age=120" } => 120,
      { "cache-control" => 'MAX-AGE="900", public' } => 900,
      { "cache-control" => "max-age=1" } => 60,
      { "cache-control" => "max-age=0" } => 60,
      { "cache-control" => "max-age=999999999" } => 86_400,
      { "cache-control" => "max-age=soon" } => 300,
      { "cache-control" => "public, max-age=300", "age" => "100" } => 200,
      { "cache-control" => "public, max-age=300", "age" => "290" } => 60,
      { "cache-control" => "public, max-age=300", "age" => "old" } => 300,
      { "cache-control" => "max-age=300, no-cache" } => 60,
      { "cache-control" => "no-store" } => 60,
      { "age" => "100" } => 300
    }.each do |headers, seconds|
      it "is #{seconds} for #{headers.inspect}" do
        expect(described_class.cache_seconds(headers)).to eq(seconds)
      end
    end
  end
end
