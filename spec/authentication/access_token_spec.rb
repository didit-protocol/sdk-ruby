# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "#verify_access_token" do
    include AuthenticationHelper

    include_context "with a stubbed issuer"

    let(:rsa_key) { OpenSSL::PKey::RSA.new(2048) }

    it "verifies an access token and returns typed claims" do
      claims = auth.verify_access_token(key.sign(access_claims(custom_claim: "kept")))

      expect(claims).to be_a(Didit::Authentication::AccessTokenClaims)
      expect([claims.iss, claims.sub, claims.sid, claims.aud]).to eq([ISSUER, IDENTITY_ID, SESSION_ID, APPLICATION_ID])
      expect(claims.client_id).to eq(APPLICATION_ID)
      expect([claims.iat, claims.exp, claims.jti]).to eq([NOW, NOW + 300, "synthetic-jti-0001"])
      expect(claims.vendor_data).to eq("user-42")
      expect(claims.amr).to eq(["passkey"])
      expect(claims.org).to be_a(Didit::Authentication::OrganizationClaim)
      expect([claims.org.id, claims.org.role]).to eq(%w[6f1c2d3e-0000-4000-8000-00000000e001 admin])
      expect([claims.verified.level, claims.verified.over_18]).to eq(["full_id", true])
      expect(claims.act).to be_nil
      expect(claims[:custom_claim]).to eq("kept")
      expect(issuer.paths).to eq([DISCOVERY, JWKS])
    end

    it "reads the actor of an agent access token" do
      act = { "sub" => "agent-0001", "agent" => "Synthetic Agent", "scopes" => ["payouts:read"] }
      claims = auth.verify_access_token(key.sign(access_claims(act: act, amr: [], verified: {})))

      expect(claims.act).to be_a(Didit::Authentication::ActorClaim)
      actor = claims.act
      expect([actor.sub, actor.agent, actor.scopes]).to eq(["agent-0001", "Synthetic Agent", ["payouts:read"]])
      expect(claims.verified.level).to be_nil
    end

    it "accepts the access token type in any case" do
      %w[at+jwt AT+JWT application/at+jwt].each do |typ|
        expect(auth.verify_access_token(key.sign(access_claims, typ: typ)).sub).to eq(IDENTITY_ID)
      end
    end

    it "rejects a token that is not an access token" do
      [nil, "JWT", "jwt", "id+jwt", "at+jwe", 1].each do |typ|
        token = key.sign(access_claims, typ: nil, header: typ.nil? ? {} : { "typ" => typ })
        expect(reason_of { auth.verify_access_token(token) }).to eq(:invalid_type)
      end
    end

    describe "audience" do
      let(:token) { key.sign(access_claims) }

      it "is checked when given, as a string or an array" do
        expect(auth.verify_access_token(token, audience: APPLICATION_ID).aud).to eq(APPLICATION_ID)
        expect(auth.verify_access_token(token, audience: ["other", APPLICATION_ID]).sub).to eq(IDENTITY_ID)
        expect(reason_of { auth.verify_access_token(token, audience: "other-application") }).to eq(:invalid_audience)
      end

      it "matches an audience in an array claim" do
        listed = key.sign(access_claims(aud: ["other", APPLICATION_ID]))
        expect(auth.verify_access_token(listed, audience: APPLICATION_ID).aud).to eq(["other", APPLICATION_ID])
      end

      it "refuses an aud claim of another shape" do
        [7, { "aud" => APPLICATION_ID }, [7, nil]].each do |odd|
          odd_token = key.sign(access_claims(aud: odd))
          expect(reason_of { auth.verify_access_token(odd_token, audience: APPLICATION_ID) }).to eq(:invalid_audience)
        end
      end

      it "is not checked without an audience, and missing when one is expected" do
        no_aud = key.sign(access_claims(aud: REMOVE))
        expect(auth.verify_access_token(no_aud).sub).to eq(IDENTITY_ID)
        expect(reason_of { auth.verify_access_token(no_aud, audience: APPLICATION_ID) }).to eq(:missing_claim)
      end

      it "must be a non-empty string or array of them" do
        ["", [], [""], [APPLICATION_ID, 7]].each do |bad|
          expect do
            auth.verify_access_token(token, audience: bad)
          end.to raise_error(Didit::ConfigurationError, /audience/)
        end
      end

      it "defaults to the client id" do
        issuer
        configured = described_class.new(ISSUER, client_id: APPLICATION_ID, clock: clock)
        other = key.sign(access_claims(aud: "another-application"))

        expect(configured.verify_access_token(token).sub).to eq(IDENTITY_ID)
        expect(reason_of { configured.verify_access_token(other) }).to eq(:invalid_audience)
        expect(configured.verify_access_token(other, audience: "another-application").sub).to eq(IDENTITY_ID)
      end
    end

    describe "algorithms" do
      it "rejects every algorithm but ES256 before any request" do
        %w[HS256 HS512 RS256 PS256 EdDSA ES384 ES512 es256 none].each do |alg|
          token = unsigned_token({ "alg" => alg, "typ" => "at+jwt", "kid" => key.kid }, access_claims, "\x01" * 64)
          expect(reason_of { auth.verify_access_token(token) }).to eq(:unsupported_algorithm)
        end
        expect(issuer.requests).to be_empty
      end

      it "rejects alg none and a header without alg" do
        [{ "alg" => "none", "kid" => key.kid }, {}].each do |header|
          token = unsigned_token(header.merge("typ" => "at+jwt"), access_claims)
          expect(token).to end_with(".")
          expect(reason_of { auth.verify_access_token(token) }).to eq(:unsupported_algorithm)
        end
        expect(issuer.requests).to be_empty
      end

      it "rejects HS256 signed with the public key (key confusion)" do
        header = { "alg" => "HS256", "typ" => "at+jwt", "kid" => key.kid }
        signing_input = "#{segment(header)}.#{segment(access_claims)}"
        [JSON.generate(key.jwk), key.private_key.public_to_pem].each do |secret|
          token = "#{signing_input}.#{b64url(OpenSSL::HMAC.digest("SHA256", secret, signing_input))}"
          expect(reason_of { auth.verify_access_token(token) }).to eq(:unsupported_algorithm)
        end
      end

      it "rejects real RS256 and PS256 tokens" do
        [["RS256", ->(input) { rsa_key.sign("SHA256", input) }],
         ["PS256", ->(input) { rsa_key.sign_pss("SHA256", input, salt_length: :digest, mgf1_hash: "SHA256") }]]
          .each do |alg, signer|
          signing_input = "#{segment({ "alg" => alg, "typ" => "at+jwt", "kid" => key.kid })}.#{segment(access_claims)}"
          token = "#{signing_input}.#{b64url(signer.call(signing_input))}"
          expect(reason_of { auth.verify_access_token(token) }).to eq(:unsupported_algorithm)
        end
      end

      it "rejects a real ES384 token" do
        p384 = OpenSSL::PKey::EC.generate("secp384r1")
        header = segment({ "alg" => "ES384", "typ" => "at+jwt", "kid" => key.kid })
        signing_input = "#{header}.#{segment(access_claims)}"
        integers = OpenSSL::ASN1.decode(p384.sign("SHA384", signing_input)).value
        signature = integers.map { |n| n.value.to_s(2).rjust(48, "\x00".b) }.join
        expect(reason_of { auth.verify_access_token("#{signing_input}.#{b64url(signature)}") })
          .to eq(:unsupported_algorithm)
      end
    end

    describe "signatures" do
      let(:token) { key.sign(access_claims) }
      let(:header_segment) { token.split(".").first }
      let(:payload_segment) { token.split(".")[1] }

      it "rejects a token signed by another key with the same kid, without echoing the token" do
        forged = AuthenticationHelper::SigningKey.generate(key.kid).sign(access_claims)
        error = error_of { auth.verify_access_token(forged) }

        expect(error).to be_a(Didit::TokenVerificationError)
        expect(error.reason).to eq(:invalid_signature)
        expect(error.message).not_to include(forged)
      end

      it "rejects tampered claims" do
        forged = "#{header_segment}.#{segment(access_claims(sub: "someone-else"))}.#{token.split(".").last}"
        expect(reason_of { auth.verify_access_token(forged) }).to eq(:invalid_signature)
      end

      it "rejects a DER-encoded signature" do
        der = key.der_signature("#{header_segment}.#{payload_segment}")
        expect(reason_of { auth.verify_access_token("#{header_segment}.#{payload_segment}.#{b64url(der)}") })
          .to eq(:invalid_signature)
      end

      it "rejects short, empty, long and zero signatures" do
        ["x" * 63, "", "x" * 65, "\x00" * 64, ("\x00" * 32) + ("\x01" * 32),
         ("\x01" * 32) + ("\x00" * 32)].each do |bytes|
          candidate = "#{header_segment}.#{payload_segment}.#{b64url(bytes)}"
          expect(reason_of { auth.verify_access_token(candidate) }).to eq(:invalid_signature)
        end
      end
    end

    describe "issuer" do
      it "must equal the configured issuer exactly" do
        other = key.sign(access_claims(iss: "https://other-0001.auth.didit.me"))
        expect(reason_of { auth.verify_access_token(other) }).to eq(:invalid_issuer)
        slash = key.sign(access_claims(iss: "#{ISSUER}/"))
        expect(reason_of { auth.verify_access_token(slash) }).to eq(:invalid_issuer)
        missing = key.sign(access_claims(iss: REMOVE))
        expect(reason_of { auth.verify_access_token(missing) }).to eq(:missing_claim)
      end

      it "is configured without its trailing slash" do
        issuer
        slashed = described_class.new("#{ISSUER}/", clock: clock)
        expect(slashed.verify_access_token(key.sign(access_claims)).iss).to eq(ISSUER)
      end
    end

    describe "time and required claims" do
      {
        { exp: NOW - 61 } => :expired,
        { exp: NOW - 60 } => :expired,
        { nbf: NOW + 120 } => :not_yet_valid,
        { iat: NOW + 120 } => :invalid_issued_at,
        { exp: REMOVE } => :missing_claim,
        { iat: REMOVE } => :missing_claim,
        { sub: REMOVE } => :missing_claim,
        { sub: "" } => :missing_claim,
        { exp: "soon" } => :malformed,
        { exp: NOW.to_s } => :malformed,
        { exp: true } => :malformed,
        { iat: [NOW] } => :malformed,
        { nbf: nil } => :malformed,
        { exp: 10**400 } => :malformed,
        { nbf: 10**400 } => :malformed
      }.each do |overrides, expected|
        it "refuses #{overrides.inspect} as #{expected}" do
          expect(reason_of { auth.verify_access_token(key.sign(access_claims(**overrides))) }).to eq(expected)
        end
      end

      it "allows sixty seconds of clock skew" do
        skews = [{ exp: NOW - 59 }, { exp: NOW + 1.5 }, { nbf: NOW + 59 }, { iat: NOW + 59 }, { nbf: NOW - 10 }]
        skews.each do |overrides|
          expect(auth.verify_access_token(key.sign(access_claims(**overrides))).sub).to eq(IDENTITY_ID)
        end
      end

      it "uses the configured leeway" do
        issuer
        strict = described_class.new(ISSUER, leeway: 0, clock: clock)
        expect(reason_of { strict.verify_access_token(key.sign(access_claims(exp: NOW))) }).to eq(:expired)
        lenient = described_class.new(ISSUER, leeway: 600, clock: clock)
        expect(lenient.verify_access_token(key.sign(access_claims(exp: NOW - 500))).sub).to eq(IDENTITY_ID)
      end

      it "rejects an infinite date in a signed token" do
        header = segment({ "alg" => "ES256", "typ" => "at+jwt", "kid" => key.kid })
        payload = b64url(JSON.generate(access_claims).sub(/"exp":\d+/, '"exp":1e400'))
        signing_input = "#{header}.#{payload}"
        token = "#{signing_input}.#{b64url(key.raw_signature(signing_input))}"
        expect(reason_of { auth.verify_access_token(token) }).to eq(:malformed)
      end
    end

    describe "malformed tokens" do
      let(:signature) { b64url("\x00" * 64) }
      let(:payload) { segment(access_claims) }
      let(:good_header) { segment({ "alg" => "ES256", "typ" => "at+jwt", "kid" => key.kid }) }
      let(:critical_header) { segment({ "alg" => "ES256", "typ" => "at+jwt", "kid" => key.kid, "crit" => ["b64"] }) }
      let(:malformed) do
        [
          "", "abc", "a.b", "a.b.c.d", "a.b.c.d.e", "..", "...",
          "!!!.#{payload}.#{signature}",
          "#{good_header}=.#{payload}.#{signature}",
          "#{b64url("not json")}.#{payload}.#{signature}",
          "#{b64url("[1, 2]")}.#{payload}.#{signature}",
          "#{b64url("\xff\xfe")}.#{payload}.#{signature}",
          "#{b64url('{"alg":"ES256","typ":"at+jwt","kid":"k","x":"\ud800"}')}.#{payload}.#{signature}",
          "#{good_header}.#{b64url("not json")}.#{signature}",
          "#{good_header}.#{b64url("[]")}.#{signature}",
          "#{good_header}.#{b64url("42")}.#{signature}",
          "#{good_header}.#{b64url("null")}.#{signature}",
          "#{good_header}.#{b64url('{"exp": NaN}')}.#{signature}",
          "#{good_header}.abcde.#{signature}",
          "#{good_header}.#{payload}.abc!",
          "#{good_header}.#{payload}.#{signature}=",
          "#{good_header}.#{b64url(("[" * 5000) + ("]" * 5000))}.#{signature}",
          "#{segment({ "alg" => "ES256", "typ" => "at+jwt" })}.#{payload}.#{signature}",
          "#{segment({ "alg" => "ES256", "typ" => "at+jwt", "kid" => 7 })}.#{payload}.#{signature}",
          "#{segment({ "alg" => "ES256", "typ" => "at+jwt", "kid" => "" })}.#{payload}.#{signature}",
          "#{critical_header}.#{payload}.#{signature}",
          "#{good_header}.#{payload}.#{signature}é",
          "x" * 20_000,
          "\xff.\xfe.\xfd",
          123, nil, :token, ["a.b.c"]
        ]
      end

      it "refuses each as malformed, before any request and without echoing it" do
        malformed.each do |token|
          error = error_of { auth.verify_access_token(token) }
          expect(error).to be_a(Didit::TokenVerificationError), "#{token.inspect[0, 80]}: #{error.inspect}"
          expect(error.reason).to eq(:malformed), "#{token.inspect[0, 80]}: #{error.reason}"
          expect(error.message).not_to include(token) if token.is_a?(String) && token.length > 10
        end
        expect(issuer.requests).to be_empty
      end

      it "refuses a validly signed token with b64 in its header, whatever the jwt gem version" do
        [false, true].each do |b64|
          token = key.sign(access_claims, header: { "b64" => b64 })
          expect(reason_of { auth.verify_access_token(token) }).to eq(:malformed)
        end
      end

      it "refuses duplicate header members, or reads the last one where JSON allows them" do
        duplicate = "#{b64url('{"alg":"ES256","alg":"none","typ":"at+jwt","kid":"k"}')}.#{payload}.#{signature}"
        expect(reason_of { auth.verify_access_token(duplicate) }).to eq(:malformed).or eq(:unsupported_algorithm)
      end

      it "never raises anything but a TokenVerificationError for random input" do
        random = Random.new(7)
        200.times do
          parts = Array.new(3) { b64url(random.bytes(random.rand(0..40))) }
          parts[0] = good_header if random.rand < 0.5
          token = parts.join(".")
          expect { auth.verify_access_token(token) }.to raise_error(Didit::TokenVerificationError)
        end
      end
    end
  end
end
