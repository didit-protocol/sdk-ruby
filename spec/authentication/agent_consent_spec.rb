# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper # rubocop:disable Metrics/ModuleLength
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
          auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve",
                                                  assertion: assertion)
        end

        [error.message, error.body.to_s].each do |text|
          [agent_challenge, ACCESS_TOKEN, "SYNTHETIC_SIGNATURE", "SYNTHETIC_CLIENT_DATA"].each do |secret|
            expect(text).not_to include(secret)
          end
        end
      end

      context "when the issuer echoes every assertion string" do
        let(:markers) do
          { id: "MARK-ID-1-padpadpad0123", raw: "MARK-RAWID-2-padpadpad0123",
            type: "MARK-TYPE-3-padpadpad0123", cdj: "MARK-CDJ-4/+=-padpad01", ad: "MARK-AD-5-padpadpad0123",
            sig: "MARK-SIG-6-padpadpad0123", handle: "MARK-HANDLE-7-padpadpad0123",
            ext: "MARK-EXT-8-padpadpad0123", deep: "MARK-DEEP-9-padpadpad0123",
            list: "MARK-LIST-10-padpadpad0123", quoted: "MARK-\"QUOTED\"-11/\n" }
        end
        let(:full_assertion) do
          m = markers
          { "id" => m[:id], "rawId" => m[:raw], "type" => m[:type],
            "response" => { "clientDataJSON" => m[:cdj], "authenticatorData" => m[:ad], "signature" => m[:sig],
                            "userHandle" => m[:handle], "transports" => [m[:list]] },
            "clientExtensionResults" => { "ext" => m[:ext],
                                          "nested" => { "deep" => [m[:deep], { "q" => m[:quoted] }] } } }
        end
        let(:secrets) { [agent_challenge, ACCESS_TOKEN, *markers.values] }

        def leaks(error, secrets)
          texts = [error.message, error.to_s, error.inspect, error.body.to_s, error.body.inspect]
          texts << error.body.to_json if error.body
          texts += error.headers.to_s.then { |h| [h] } if error.respond_to?(:headers)
          texts.flat_map { |t| secrets.select { |s| t.include?(s) || t.include?(s.to_json[1..-2]) } }.uniq
        end

        def submit
          error_of do
            auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve",
                                                    assertion: full_assertion)
          end
        end

        it "keeps all of them out of a 400 error" do
          echo = { "detail" => "passkey_required", "echo" => full_assertion.merge("challenge" => agent_challenge,
                                                                                  "token" => ACCESS_TOKEN) }
          issuer.reply(:post, "/agents/consent/", 400, echo)
          error = submit

          expect(error).to be_a(Didit::BadRequestError)
          expect(leaks(error, secrets)).to eq([])
          expect(error.body["detail"]).to eq("passkey_required")
        end

        it "keeps all of them out of a text 400 body, JSON-escaped form included" do
          issuer.route(:post, "/agents/consent/") do
            { status: 400, headers: { "Content-Type" => "text/plain" },
              body: "bad #{JSON.generate(full_assertion)} #{agent_challenge}" }
          end
          error = submit

          expect(leaks(error, secrets)).to eq([])
        end

        it "keeps a non-ASCII secret out of a text body that echoes it as ASCII-only JSON escapes" do
          accented = "MARK-café-\u{1F600}-12-padpad"
          assertion = full_assertion.merge("extra" => accented)
          issuer.route(:post, "/agents/consent/") do
            { status: 400, headers: { "Content-Type" => "text/plain" },
              body: "bad #{JSON.generate(assertion, ascii_only: true)}" }
          end
          error = error_of do
            auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve",
                                                    assertion: assertion)
          end

          expect(leaks(error, [accented])).to eq([])
          expect([error.message, error.body.to_s].join).not_to include("caf\\u00e9", "\\ud83d\\ude00")
        end

        it "keeps all of them out of a malformed 200" do
          issuer.route(:post, "/agents/consent/") do
            { status: 200, headers: { "Content-Type" => "text/html" },
              body: "<p>#{JSON.generate(full_assertion)} #{agent_challenge} #{ACCESS_TOKEN}</p>" }
          end
          error = submit

          expect(error).to be_a(Didit::APIResponseValidationError)
          expect(leaks(error, secrets)).to eq([])
        end

        it "keeps all of them out of a 200 JSON array" do
          issuer.reply(:post, "/agents/consent/", 200, [full_assertion, agent_challenge])
          error = submit

          expect(error).to be_a(Didit::APIResponseValidationError)
          expect(leaks(error, secrets)).to eq([])
        end
      end

      context "when redacting structurally" do
        let(:short) { "abcCREDENTIALID0123" }
        let(:long) { "abcCREDENTIALID0123456789" }

        def submit_with(assertion)
          error_of do
            auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve",
                                                    assertion: assertion)
          end
        end

        def shown(error)
          [error.message, error.to_s, error.inspect, error.body.inspect, error.body.to_json].join("\n")
        end

        def reply_json(status, body, path = "/agents/consent/")
          issuer.route(:post, path) do
            { status: status, headers: { "Content-Type" => "application/json" }, body: body }
          end
        end

        it "leaves no fragment of a secret that another secret prefixes" do
          reply_json(400, JSON.generate("detail" => "bad #{long} and #{short}", "other" => long))
          error = submit_with({ "id" => short, "signature" => long })

          expect(shown(error)).not_to match(/abcCRED|456789/)
          expect(error.body).to eq("detail" => "[redacted]", "other" => "[redacted]")
        end

        it "redacts the whole string that contains a secret" do
          reply_json(400, JSON.generate("detail" => "bad assertion xyzSECRET-0123456789abcdefxyz", "keep" => "fine"))
          error = submit_with({ "id" => "SECRET-0123456789abcdef" })

          expect(error.body).to eq("detail" => "[redacted]", "keep" => "fine")
          expect(error.message).to start_with("HTTP 400: [redacted]")
        end

        it "redacts a secret used as an object key and numbers colliding keys" do
          reply_json(400,
                     JSON.generate("detail" => "no", "echo-SECRET-0123456789abcdef-1" => "a",
                                   "echo-SECRET-0123456789abcdef-2" => "b"))
          error = submit_with({ "id" => "SECRET-0123456789abcdef" })

          expect(error.body).to eq("detail" => "no", "[redacted]" => "a", "[redacted]2" => "b")
          expect(shown(error)).not_to include("SECRET-0123456789abcdef")
        end

        it "redacts a secret echoed with other JSON escape spellings" do
          secret = "a/b+\u00e9-padding0123456"
          body = '{"detail":"x","echo":"a\\/b+\\u00E9-padding0123456"}'
          reply_json(400, body)
          error = submit_with({ "id" => secret })

          expect(JSON.parse(body)["echo"]).to eq(secret)
          expect(error.body).to eq("detail" => "x", "echo" => "[redacted]")
          expect(shown(error)).not_to include("a/b", "00E9", "\u00e9", "padding0123456")
        end

        it "keeps an error code and short assertion strings readable while redacting long values" do
          long = "Y3JlZGVudGlhbC1pZC0xMjM0NTY3ODkw"
          reply_json(400, JSON.generate("error" => "invalid_grant", "detail" => "id public-key #{long}"))
          error = submit_with({ "id" => long, "type" => "public-key" })

          expect(error.body).to eq("error" => "invalid_grant", "detail" => "[redacted]")
          expect(error.message).to start_with("HTTP 400: ")
          expect(shown(error)).to include("invalid_grant")
          expect(shown(error)).not_to include(long)
        end

        it "redacts a string inside a nested object that serialises itself" do
          nested = "nested-credential-string-0123456789"
          extension = Class.new do
            define_method(:to_json) { |*args| { "credProps" => { "deep" => [{ "value" => nested }] } }.to_json(*args) }
          end.new
          reply_json(400, JSON.generate("error" => "invalid_grant", "echo" => nested))
          error = submit_with({ "id" => "short", "clientExtensionResults" => extension })

          expect(error.body).to eq("error" => "invalid_grant", "echo" => "[redacted]")
          expect(shown(error)).not_to include(nested)
        end

        it "reads the secrets from the bytes sent, not from a second serialization" do
          sent = "credential-string-actually-sent-0123"
          calls = 0
          extension = Object.new
          extension.define_singleton_method(:to_json) do |*args|
            calls += 1
            raise "serialized twice" if calls > 1

            { "credProps" => { "value" => sent } }.to_json(*args)
          end
          reply_json(400, JSON.generate("error" => "invalid_grant", "echo" => sent))
          error = submit_with({ "id" => "short", "clientExtensionResults" => extension })

          expect(error.body).to eq("error" => "invalid_grant", "echo" => "[redacted]")
          expect(shown(error)).not_to include(sent)
        end

        it "turns an empty body into [redacted]" do
          issuer.route(:post, "/agents/consent/") { { status: 502, headers: {}, body: "" } }
          error = submit_with({ "id" => "short" })

          expect(error.body).to eq("[redacted]")
        end

        it "keeps a safe key named [redacted] after a secret key" do
          secret = "SECRET-0123456789abcdef"
          reply_json(400, %({"a-#{secret}":"x","[redacted]":"safe"}))
          error = submit_with({ "id" => secret })

          expect(error.body).to eq("[redacted]2" => "x", "[redacted]" => "safe")
        end

        it "redacts the request id and headers" do
          credential = "credential-string-0123456789"
          issuer.route(:post, "/agents/consent/") do
            { status: 400, body: '{"error":"invalid_grant"}',
              headers: { "Content-Type" => "application/json", "X-Request-Id" => "req-#{credential}",
                         "X-Echo" => credential } }
          end
          error = submit_with({ "id" => credential })

          expect(error.request_id).to eq("[redacted]")
          expect(error.message).not_to include(credential)
          expect(error.headers.to_s).not_to include(credential)
        end

        [Errno::ECONNRESET, RuntimeError].each do |raised|
          it "keeps no text or cause of a #{raised} transport failure" do
            credential = 'cred"ential\\string-0123456789'
            issuer
            stub_request(:post, "#{ISSUER}/agents/consent/")
              .to_raise(raised.new("write failed: #{JSON.generate("id" => credential)}"))
            error = error_of do
              auth.submit_agent_consent(ACCESS_TOKEN, challenge: agent_challenge, decision: "approve",
                                                      assertion: { "id" => credential })
            end

            expect(error).to be_a(Didit::APIConnectionError)
            expect(error.cause).to be_nil
            expect([error.message, error.inspect].join).not_to match(/ential|write failed/)
          end
        end

        it "replaces a non-JSON body with [redacted] on the error" do
          issuer.route(:post, "/agents/consent/") do
            { status: 502, headers: { "Content-Type" => "text/html" },
              body: "<html>Bad gateway #{agent_challenge}</html>" }
          end
          error = submit_with(assertion)

          expect(error.body).to eq("[redacted]")
          expect(shown(error)).not_to include(agent_challenge)
        end

        it "redacts a secret that sits past the length of a long body" do
          issuer.route(:post, "/agents/consent/") do
            { status: 400, headers: { "Content-Type" => "text/plain" }, body: "#{"x" * 600} #{agent_challenge}" }
          end
          error = submit_with(assertion)

          expect(error.body).to eq("[redacted]")
          expect(shown(error)).not_to include(agent_challenge)
        end

        it "redacts the options call from the parsed body too" do
          reply_json(400, JSON.generate("detail" => "bad #{agent_challenge}"), "/agents/consent/passkey/")
          error = error_of { auth.create_agent_approval_options(ACCESS_TOKEN, challenge: agent_challenge) }

          expect(error.body).to eq("detail" => "[redacted]")
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
        expect(error.message).to start_with("HTTP 403: [redacted]")
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
