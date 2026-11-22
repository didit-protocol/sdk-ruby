# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "agent consent" do
    include AuthenticationHelper

    include_context "with a stubbed issuer"

    def json_of(request)
      JSON.parse(request.body)
    end

    let(:agent_challenge) { "synthetic-agent-challenge-0001" }
    let(:assertion) do
      {
        "id" => "c3ludGhldGljLWNyZWRlbnRpYWw", "rawId" => "c3ludGhldGljLWNyZWRlbnRpYWw", "type" => "public-key",
        "response" => { "clientDataJSON" => "SYNTHETIC_CLIENT_DATA", "authenticatorData" => "SYNTHETIC_AUTH_DATA",
                        "signature" => "SYNTHETIC_SIGNATURE", "userHandle" => nil }
      }
    end
    let(:approved) { { "code" => "synthetic-agent-code", "redirect_uri" => "https://agent.example/callback", "state" => "s1" } }

    describe "#submit_agent_consent" do
      it "posts the approval as JSON and reads the code, redirect URI and state" do
        issuer.reply(:post, "/agents/consent/", 200, approved)
        consent = auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: :approve,
                                                          assertion: assertion, scopes: ["read"])

        expect(consent).to be_a(Didit::Authentication::AgentConsent)
        expect([consent.approved?, consent.denied?, consent.code, consent.redirect_uri, consent.state])
          .to eq([true, false, "synthetic-agent-code", "https://agent.example/callback", "s1"])
        request = issuer.last("/agents/consent/")
        expect([request.method, request.headers["Authorization"], request.headers["Content-Type"]])
          .to eq([:post, "Bearer #{ACCESS_TOKEN}", "application/json"])
        expect(json_of(request)).to eq("challenge" => agent_challenge, "decision" => "approve",
                                       "assertion" => assertion, "scopes" => ["read"])
        expect(consent.inspect).not_to include("synthetic-agent-code")
      end

      it "reads a denial" do
        issuer.reply(:post, "/agents/consent/", 200, { "status" => "denied" })
        consent = auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "deny")

        expect([consent.approved?, consent.denied?, consent.status, consent.code]).to eq([false, true, "denied", nil])
        expect(json_of(issuer.last("/agents/consent/"))).to eq("challenge" => agent_challenge, "decision" => "deny")
      end

      {
        [400, { "error" => "invalid_grant" }] => [Didit::BadRequestError, "HTTP 400: invalid_grant"],
        [403, { "detail" => "passkey_required" }] => [Didit::PermissionDeniedError, "HTTP 403: passkey_required"],
        [401, { "detail" => "invalid_token" }] => [Didit::AuthenticationError, "HTTP 401: invalid_token"],
        [429, { "detail" => "Too many requests." }] => [Didit::RateLimitError, "HTTP 429: Too many requests."],
        [503, { "detail" => "unavailable" }] => [Didit::InternalServerError, "HTTP 503: unavailable"]
      }.each do |(status, body), (error_class, message)|
        it "maps HTTP #{status} to #{error_class} and never retries the POST" do
          issuer.reply(:post, "/agents/consent/", status, body)
          error = error_of do
            auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve")
          end

          expect(error.class).to eq(error_class)
          expect([error.status, error.body]).to eq([status, body])
          expect(error.message).to start_with(message)
          expect(issuer.count("/agents/consent/")).to eq(1)
        end
      end

      it "redacts the challenge, access token and assertion from error messages and bodies" do
        echoed = [agent_challenge, ACCESS_TOKEN, "SYNTHETIC_SIGNATURE", "SYNTHETIC_CLIENT_DATA"].join(" ")
        issuer.reply(:post, "/agents/consent/", 400, { "detail" => echoed })
        error = error_of do
          auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve", assertion: assertion)
        end

        [error.message, error.body.to_s].each do |text|
          [agent_challenge, ACCESS_TOKEN, "SYNTHETIC_SIGNATURE", "SYNTHETIC_CLIENT_DATA"].each do |secret|
            expect(text).not_to include(secret)
          end
        end
      end

      it "checks the arguments before any request" do
        expect { auth.submit_agent_consent(ACCESS_TOKEN, challenge: " ", decision: "approve") }
          .to raise_error(Didit::ConfigurationError, /challenge is empty/)
        expect { auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "maybe") }
          .to raise_error(Didit::ConfigurationError, /decision/)
        expect do
          auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve", assertion: "x")
        end
          .to raise_error(Didit::ConfigurationError, /assertion/)
        expect { auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve", scopes: []) }
          .to raise_error(Didit::ConfigurationError, /scopes/)
        expect(issuer.requests).to be_empty
      end
    end

    describe "#create_agent_approval_options" do
      let(:options_response) do
        { "options" => { "challenge" => "c3ludGhldGljLWNoYWxsZW5nZQ", "rpId" => "acme.auth.didit.me",
                         "timeout" => 60_000,
                         "userVerification" => "required",
                         "allowCredentials" => [{ "id" => "c3ludGhldGljLWNyZWRlbnRpYWw", "type" => "public-key" }] } }
      end

      it "posts the challenge as JSON and reads the WebAuthn options" do
        issuer.reply(:post, "/agents/consent/passkey/", 200, options_response)
        result = auth.create_agent_approval_options(ACCESS_TOKEN, challenge: agent_challenge)

        options = result.options
        expect(options).to be_a(Didit::Authentication::AgentWebAuthnOptions)
        expect([options.challenge, options.rp_id, options.timeout, options.user_verification])
          .to eq(["c3ludGhldGljLWNoYWxsZW5nZQ", "acme.auth.didit.me", 60_000, "required"])
        expect(options.allow_credentials.map(&:id)).to eq(["c3ludGhldGljLWNyZWRlbnRpYWw"])
        request = issuer.last("/agents/consent/passkey/")
        expect([request.method, request.headers["Authorization"]]).to eq([:post, "Bearer #{ACCESS_TOKEN}"])
        expect(json_of(request)).to eq("challenge" => agent_challenge)
      end

      it "maps 403 passkey_required without retrying and redacts the challenge" do
        issuer.reply(:post, "/agents/consent/passkey/", 403, { "detail" => "passkey_required #{agent_challenge}" })
        error = error_of { auth.create_agent_approval_options(ACCESS_TOKEN, challenge: agent_challenge) }

        expect(error).to be_a(Didit::PermissionDeniedError)
        expect(error.message).to start_with("HTTP 403: passkey_required [redacted]")
        expect(issuer.count("/agents/consent/passkey/")).to eq(1)
      end

      it "refuses an empty challenge before any request" do
        expect { auth.create_agent_approval_options(ACCESS_TOKEN, challenge: "") }
          .to raise_error(Didit::ConfigurationError, /challenge/)
        expect(issuer.requests).to be_empty
      end
    end
  end
end
