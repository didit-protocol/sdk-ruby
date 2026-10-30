# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "#verify_id_token" do
    include AuthenticationHelper

    include_context "with a stubbed issuer"

    let(:token) { key.sign(id_claims, typ: "JWT") }

    def verify(candidate, nonce: NONCE, audience: APPLICATION_ID)
      auth.verify_id_token(candidate, nonce: nonce, audience: audience)
    end

    it "verifies an ID token and returns typed claims" do
      claims = verify(token)

      expect(claims).to be_a(Didit::Authentication::IdTokenClaims)
      expect([claims.sub, claims.sid, claims.nonce]).to eq([IDENTITY_ID, SESSION_ID, NONCE])
      expect([claims.email, claims.email_verified, claims.name]).to eq(["person@example.com", true, "Synthetic Person"])
      expect(claims.auth_time).to eq(NOW - 10)
      expect(claims.phone_number).to be_nil
      expect(claims.org).to be_nil
      expect(claims.amr).to eq(["password"])
    end

    it "accepts typ JWT in any case, application/jwt, or no typ" do
      ["JWT", "jwt", "application/jwt", nil].each do |typ|
        expect(verify(key.sign(id_claims, typ: typ)).sub).to eq(IDENTITY_ID)
      end
    end

    it "never takes an access token as an ID token" do
      ["at+jwt", "application/at+jwt", "dpop+jwt", 1].each do |typ|
        candidate = key.sign(id_claims, typ: nil, header: { "typ" => typ })
        expect(reason_of { verify(candidate) }).to eq(:invalid_type)
      end
    end

    describe "nonce" do
      it "must match this sign-in" do
        expect(reason_of { verify(token, nonce: "another-sign-in") }).to eq(:invalid_nonce)
        expect(reason_of { verify(token, nonce: "#{NONCE}x") }).to eq(:invalid_nonce)
      end

      it "must be present when one is expected" do
        no_nonce = key.sign(id_claims(nonce: REMOVE), typ: "JWT")
        expect(reason_of { verify(no_nonce) }).to eq(:invalid_nonce)
        not_text = key.sign(id_claims(nonce: 42), typ: "JWT")
        expect(reason_of { verify(not_text) }).to eq(:invalid_nonce)
      end

      it "must be absent with nonce: nil, the case of an ID token from refresh" do
        refreshed = key.sign(id_claims(nonce: REMOVE), typ: "JWT")
        expect(verify(refreshed, nonce: nil).nonce).to be_nil
        expect(reason_of { verify(token, nonce: nil) }).to eq(:invalid_nonce)
      end

      it "must not be an empty string" do
        expect { verify(token, nonce: "") }.to raise_error(Didit::ConfigurationError, /nonce/)
        expect { verify(token, nonce: 42) }.to raise_error(Didit::ConfigurationError, /nonce/)
      end
    end

    describe "audience" do
      it "is required, from the argument or the client id, before any request" do
        expect { auth.verify_id_token(token, nonce: NONCE) }.to raise_error(Didit::ConfigurationError, /audience/)
        expect(issuer.requests).to be_empty

        configured = described_class.new(ISSUER, client_id: APPLICATION_ID, clock: clock)
        expect(configured.verify_id_token(token, nonce: NONCE).aud).to eq(APPLICATION_ID)
      end

      it "must match" do
        expect(reason_of { verify(token, audience: "other") }).to eq(:invalid_audience)
        no_aud = key.sign(id_claims(aud: REMOVE), typ: "JWT")
        expect(reason_of { verify(no_aud) }).to eq(:missing_claim)
      end
    end

    it "makes the same time, issuer and signature checks as access tokens" do
      expect(reason_of { verify(key.sign(id_claims(exp: NOW - 120), typ: "JWT")) }).to eq(:expired)
      expect(reason_of { verify(key.sign(id_claims(iat: NOW + 120), typ: "JWT")) }).to eq(:invalid_issued_at)
      expect(reason_of { verify(key.sign(id_claims(iss: "https://other.auth.didit.me"), typ: "JWT")) })
        .to eq(:invalid_issuer)
      other = AuthenticationHelper::SigningKey.generate(key.kid).sign(id_claims, typ: "JWT")
      expect(reason_of { verify(other) }).to eq(:invalid_signature)
      none = unsigned_token({ "alg" => "none", "typ" => "JWT" }, id_claims)
      expect(reason_of { verify(none) }).to eq(:unsupported_algorithm)
    end
  end
end
