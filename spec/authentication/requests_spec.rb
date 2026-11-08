# frozen_string_literal: true

require "bigdecimal"
require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "requests" do
    include AuthenticationHelper

    include_context "with a stubbed issuer"

    let(:session_response) do
      {
        "sub" => IDENTITY_ID, "sid" => SESSION_ID, "application_id" => APPLICATION_ID, "vendor_data" => "user-42",
        "amr" => ["passkey"], "mfa_verified" => true, "email" => "person@example.com", "email_verified" => true,
        "phone" => nil, "verified_identity" => nil, "verified" => { "level" => "liveness", "liveness" => true },
        "expires_at" => "2027-01-15T10:00:00Z", "post_logout_redirect_uri" => "https://app.example.com/signed-out",
        "organizations" => [
          {
            "organization_id" => "6f1c2d3e-0000-4000-8000-00000000e001", "organization__name" => "Acme Treasury",
            "role" => "admin", "custom_role" => { "key" => "approver", "permissions" => ["payouts:approve"] }
          }
        ]
      }
    end
    let(:step_up_required) do
      {
        "id" => STEP_UP_ID, "rule" => "payout", "method" => "selfie", "status" => "pending", "level" => nil,
        "amount" => "1500.00", "currency" => "EUR", "created_at" => "2027-01-15T10:00:00Z", "completed_at" => nil,
        "expires_at" => "2027-01-15T10:30:00Z", "required" => true,
        "verification_url" => "#{ISSUER}/verify/?verification=synthetic-proof", "expires_in" => 1800
      }
    end

    def json_of(request)
      JSON.parse(request.body)
    end

    describe "#exchange_code" do
      it "posts the code, verifier and redirect URI as a form to the discovered token endpoint" do
        issuer.reply(:post, "/token/", 200, TOKEN_RESPONSE)
        tokens = auth.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI)

        expect(tokens).to be_a(Didit::Authentication::TokenResponse)
        expect([tokens.access_token, tokens.id_token, tokens.refresh_token])
          .to eq(["synthetic.access.jwt", "synthetic.id.jwt", "synthetic-refresh-token-0002"])
        expect([tokens.token_type, tokens.expires_in, tokens.session_id]).to eq(["Bearer", 300, SESSION_ID])
        expect(issuer.requests.map { |r| [r.method, r.uri.path] }).to eq([[:get, DISCOVERY], [:post, "/token/"]])

        request = issuer.last("/token/")
        expect(request.uri.to_s).to eq("#{ISSUER}:443/token/").or eq("#{ISSUER}/token/")
        expect(request.headers["Content-Type"]).to eq("application/x-www-form-urlencoded")
        expect(request.headers["Accept"]).to eq("application/json")
        expect(request.headers["X-Didit-Client"]).to eq("ruby/#{Didit::VERSION}")
        expect(request.headers.keys.map(&:downcase)).not_to include("authorization", "x-api-key")
        expect(form_of(request)).to eq(
          "grant_type" => "authorization_code", "code" => CODE, "code_verifier" => CODE_VERIFIER,
          "redirect_uri" => REDIRECT_URI
        )
      end

      it "keeps the tokens out of inspect" do
        issuer.reply(:post, "/token/", 200, TOKEN_RESPONSE)
        tokens = auth.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI)
        %w[synthetic.access.jwt synthetic.id.jwt synthetic-refresh-token-0002].each do |secret|
          expect(tokens.inspect).not_to include(secret)
          expect(tokens.to_s).not_to include(secret)
        end
        expect(tokens.inspect).to include("[redacted]", SESSION_ID)
      end

      it "needs every argument, before any request" do
        expect { auth.exchange_code("", code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI) }
          .to raise_error(Didit::ConfigurationError, /code is empty/)
        expect { auth.exchange_code(CODE, code_verifier: " ", redirect_uri: REDIRECT_URI) }
          .to raise_error(Didit::ConfigurationError, /code_verifier/)
        expect { auth.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: nil) }
          .to raise_error(Didit::ConfigurationError, /redirect_uri/)
        expect(issuer.requests).to be_empty
      end
    end

    describe "#refresh" do
      it "posts the refresh token to the discovered token endpoint" do
        issuer.discovery["token_endpoint"] = "#{ISSUER}/oauth/token/"
        issuer.reply(:post, "/oauth/token/", 200, TOKEN_RESPONSE)

        expect(auth.refresh(REFRESH_TOKEN).refresh_token).to eq("synthetic-refresh-token-0002")
        expect(form_of(issuer.last("/oauth/token/")))
          .to eq("grant_type" => "refresh_token", "refresh_token" => REFRESH_TOKEN)
      end

      it "needs a refresh token" do
        expect { auth.refresh("") }.to raise_error(Didit::ConfigurationError, /refresh_token/)
        expect { auth.refresh(nil) }.to raise_error(Didit::ConfigurationError, /refresh_token/)
        expect(issuer.requests).to be_empty
      end
    end

    it "sends the client id with token requests when configured, discovering once" do
      issuer.reply(:post, "/token/", 200, TOKEN_RESPONSE)
      configured = described_class.new(ISSUER, client_id: APPLICATION_ID, clock: clock)
      configured.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI)
      expect(form_of(issuer.last("/token/"))).to eq(
        "grant_type" => "authorization_code", "code" => CODE, "code_verifier" => CODE_VERIFIER,
        "redirect_uri" => REDIRECT_URI, "client_id" => APPLICATION_ID
      )

      configured.refresh(REFRESH_TOKEN)
      expect(form_of(issuer.last("/token/"))).to eq(
        "grant_type" => "refresh_token", "refresh_token" => REFRESH_TOKEN, "client_id" => APPLICATION_ID
      )
      expect(issuer.count(DISCOVERY)).to eq(1)
    end

    describe "#get_session" do
      it "reads the live session with the access token, without discovery" do
        issuer.reply(:get, "/session/", 200, session_response)
        session = auth.get_session(ACCESS_TOKEN)

        expect(session).to be_a(Didit::Authentication::Session)
        expect([session.sub, session.sid, session.application_id]).to eq([IDENTITY_ID, SESSION_ID, APPLICATION_ID])
        expect(session.expires_at).to eq(Time.utc(2027, 1, 15, 10, 0, 0))
        expect([session.mfa_verified, session.verified.level]).to eq([true, "liveness"])
        organization = session.organizations.first
        expect([organization.organization_name, organization.role]).to eq(["Acme Treasury", "admin"])
        expect(organization.custom_role.permissions).to eq(["payouts:approve"])
        expect(session.to_h[:organizations].first[:organization__name]).to eq("Acme Treasury")

        request = issuer.last("/session/")
        expect(request.method).to eq(:get)
        expect(request.headers["Authorization"]).to eq("Bearer #{ACCESS_TOKEN}")
        expect(request.headers["Accept"]).to eq("application/json")
        expect(request.body.to_s).to eq("")
        expect(issuer.count(DISCOVERY)).to eq(0)
      end

      it "needs a usable access token" do
        expect { auth.get_session("") }.to raise_error(Didit::ConfigurationError, /access_token is empty/)
        expect { auth.get_session("a b") }.to raise_error(Didit::ConfigurationError, /invalid characters/)
        expect { auth.get_session("abc\r\nX-Injected: 1") }.to raise_error(Didit::ConfigurationError, /invalid/)
        expect(issuer.requests).to be_empty
      end
    end

    describe "#revoke_session" do
      it "deletes the session and returns nil" do
        issuer.reply(:delete, "/session/", 204)

        expect(auth.revoke_session(ACCESS_TOKEN)).to be_nil
        request = issuer.last("/session/")
        expect([request.method, request.headers["Authorization"]]).to eq([:delete, "Bearer #{ACCESS_TOKEN}"])
      end

      it "accepts a JSON answer too" do
        issuer.reply(:delete, "/session/", 200, { "detail" => "signed out" })
        expect(auth.revoke_session(ACCESS_TOKEN)).to be_nil
      end
    end

    describe "#create_step_up" do
      it "posts the action as JSON and reads a required step-up (201)" do
        issuer.reply(:post, "/step-up/", 201, step_up_required)
        step_up = auth.create_step_up(ACCESS_TOKEN, action: "payout", amount: BigDecimal("1500.00"), currency: "EUR",
                                                    return_to: "https://app.example.com/payouts")

        expect(step_up).to be_a(Didit::Authentication::StepUp)
        expect([step_up.required, step_up.id, step_up.status, step_up.approved?])
          .to eq([true, STEP_UP_ID, "pending", false])
        expect(step_up.verification_url).to eq("#{ISSUER}/verify/?verification=synthetic-proof")
        expect([step_up.expires_in, step_up.amount, step_up.rule, step_up.verification_method])
          .to eq([1800, "1500.00", "payout", "selfie"])
        expect(step_up[:method]).to eq("selfie")
        expect(step_up.expires_at).to eq(Time.utc(2027, 1, 15, 10, 30, 0))

        request = issuer.last("/step-up/")
        expect(request.headers["Authorization"]).to eq("Bearer #{ACCESS_TOKEN}")
        expect(request.headers["Content-Type"]).to eq("application/json")
        expect(json_of(request)).to eq(
          "action" => "payout", "amount" => "1500", "currency" => "EUR", "return_to" => "https://app.example.com/payouts"
        )
      end

      it "reads required: false (200) and leaves out the arguments not given" do
        issuer.reply(:post, "/step-up/", 200, { "required" => false })
        step_up = auth.create_step_up(ACCESS_TOKEN, action: "contact", return_to: "https://app.example.com/profile")

        expect([step_up.required, step_up.id, step_up.approved?]).to eq([false, nil, false])
        expect(json_of(issuer.last("/step-up/"))).to eq("action" => "contact", "return_to" => "https://app.example.com/profile")
        auth.create_step_up(ACCESS_TOKEN, action: "bank")
        expect(json_of(issuer.last("/step-up/"))).to eq("action" => "bank")
      end

      {
        "1500.00" => "1500.00", " 12.5 " => "12.5", 1500 => "1500", -3 => "-3", 1500.5 => "1500.5", 0.1 => "0.1",
        1e-05 => "0.00001", 1.5e-05 => "0.000015", 1e16 => "10000000000000000", 1500.0 => "1500.0",
        BigDecimal("1E+3") => "1000", BigDecimal("12.30") => "12.3", BigDecimal("0.000001") => "0.000001",
        BigDecimal("-2.5") => "-2.5"
      }.each do |amount, sent|
        it "sends the amount #{amount.inspect} as #{sent.inspect}" do
          issuer.reply(:post, "/step-up/", 200, { "required" => false })
          auth.create_step_up(ACCESS_TOKEN, action: "payout", amount: amount, return_to: REDIRECT_URI)
          expect(json_of(issuer.last("/step-up/"))["amount"]).to eq(sent)
        end
      end

      it "refuses amounts that are not finite decimals, before any request" do
        [true, [1], Object.new, Rational(3, 2), Complex(1, 1), Float::NAN, Float::INFINITY, BigDecimal("NaN"),
         BigDecimal("Infinity"), "Infinity", "12,50", "", "1_000", "1e3", "١٠", "NaN", "+5", ".5"].each do |bad|
          expect { auth.create_step_up(ACCESS_TOKEN, action: "payout", amount: bad) }
            .to raise_error(Didit::ConfigurationError, /amount/)
        end
        expect(issuer.requests).to be_empty
      end

      it "needs an action and string currency and return_to" do
        expect { auth.create_step_up(ACCESS_TOKEN, action: "") }.to raise_error(Didit::ConfigurationError, /action/)
        expect { auth.create_step_up(ACCESS_TOKEN, action: "bank", currency: 978) }
          .to raise_error(Didit::ConfigurationError, /currency/)
        expect { auth.create_step_up(ACCESS_TOKEN, action: "bank", return_to: :home) }
          .to raise_error(Didit::ConfigurationError, /return_to/)
        expect { auth.create_step_up("", action: "bank") }.to raise_error(Didit::ConfigurationError, /access_token/)
        expect(issuer.requests).to be_empty
      end
    end

    describe "#retrieve_step_up" do
      let(:body) { step_up_required.except("required", "verification_url", "expires_in") }

      %w[approved pending review declined expired superseded some_future_status].each do |status|
        it "reads status #{status}, approved? only for approved" do
          issuer.reply(:get, "/step-up/#{STEP_UP_ID}/", 200, body.merge("status" => status))
          step_up = auth.retrieve_step_up(ACCESS_TOKEN, STEP_UP_ID)

          expect([step_up.status, step_up.approved?, step_up.required]).to eq([status, status == "approved", nil])
          request = issuer.last("/step-up/#{STEP_UP_ID}/")
          expect([request.method, request.headers["Authorization"]]).to eq([:get, "Bearer #{ACCESS_TOKEN}"])
        end
      end

      it "percent-encodes the id as one path segment" do
        expect { auth.retrieve_step_up(ACCESS_TOKEN, "a/b c?d#e%") }.to raise_error(Didit::NotFoundError)
        expect(issuer.requests.last.uri.to_s).to end_with("/step-up/a%2Fb%20c%3Fd%23e%25/")
      end

      it "refuses an empty id, '.' and '..', before any request" do
        ["", ".", "..", nil, 42].each do |bad|
          expect { auth.retrieve_step_up(ACCESS_TOKEN, bad) }.to raise_error(Didit::ConfigurationError, /step_up_id/)
        end
        expect(issuer.requests).to be_empty
      end
    end
  end
end
