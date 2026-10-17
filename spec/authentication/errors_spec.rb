# frozen_string_literal: true

require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "errors" do
    include AuthenticationHelper
    include_context "with a stubbed issuer"

    {
      [400, { "error" => "invalid_grant" }] => [Didit::BadRequestError, "HTTP 400: invalid_grant"],
      [400, { "error" => "invalid_grant", "error_description" => "The refresh token was already used." }] =>
        [Didit::BadRequestError, "HTTP 400: invalid_grant: The refresh token was already used."],
      [401, { "detail" => "invalid_token" }] => [Didit::AuthenticationError, "HTTP 401: invalid_token"],
      [403, { "detail" => "origin_not_allowed" }] => [Didit::PermissionDeniedError, "HTTP 403: origin_not_allowed"],
      [404, { "detail" => "Not found." }] => [Didit::NotFoundError, "HTTP 404: Not found."],
      [409, { "detail" => "conflict" }] => [Didit::ConflictError, "HTTP 409: conflict"],
      [429, { "detail" => "Too many requests." }] => [Didit::RateLimitError, "HTTP 429: Too many requests."],
      [500, nil] => [Didit::InternalServerError, "HTTP 500"],
      [503, { "detail" => "unavailable" }] => [Didit::InternalServerError, "HTTP 503: unavailable"],
      [418, { "detail" => "teapot" }] => [Didit::APIStatusError, "HTTP 418: teapot"],
      [302, nil] => [Didit::APIStatusError, "HTTP 302"]
    }.each do |(status, body), (error_class, message)|
      it "maps HTTP #{status} #{body.inspect} to #{error_class}, without retrying" do
        issuer.reply(:post, "/token/", status, body)
        error = error_of { auth.refresh(REFRESH_TOKEN) }

        expect(error.class).to eq(error_class)
        expect([error.status, error.body]).to eq([status, body])
        expect(error.message).to start_with(message)
        expect(error.message).not_to include(REFRESH_TOKEN)
        expect(error.request_id).to eq("req_synthetic") unless body.nil?
        expect(issuer.count("/token/")).to eq(1)
      end
    end

    it "does not follow a redirect" do
      issuer.route(:get, "/session/") { { status: 307, headers: { "Location" => "https://evil.example/session/" } } }

      expect { auth.get_session(ACCESS_TOKEN) }.to raise_error(Didit::APIStatusError) { |e| expect(e.status).to eq(307) }
      expect(issuer.count("/session/")).to eq(1)
    end

    it "redacts echoed tokens, codes and verifiers from messages and bodies" do
      issuer.reply(:post, "/token/", 400, { "detail" => "bad token #{REFRESH_TOKEN}" })
      error = error_of { auth.refresh(REFRESH_TOKEN) }
      expect(error.message).to eq("HTTP 400: bad token [redacted] (request id req_synthetic)")
      expect(error.body).to eq("detail" => "bad token [redacted]")

      issuer.reply(:get, "/session/", 401, { "detail" => "#{ACCESS_TOKEN} is not valid" })
      error = error_of { auth.get_session(ACCESS_TOKEN) }
      expect([error.message, error.body.to_s]).to all(satisfy { |text| !text.include?(ACCESS_TOKEN) })

      issuer.reply(:post, "/token/", 400, { "detail" => "#{CODE} / #{CODE_VERIFIER}" })
      error = error_of { auth.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI) }
      [error.message, error.body.to_s].each do |text|
        expect(text).not_to include(CODE)
        expect(text).not_to include(CODE_VERIFIER)
      end
    end

    it "redacts the access token from a step-up error" do
      issuer.route(:post, "/step-up/") { { status: 400, body: "token #{ACCESS_TOKEN} refused" } }
      error = error_of { auth.create_step_up(ACCESS_TOKEN, action: "bank") }
      expect(error).to be_a(Didit::BadRequestError)
      expect([error.message, error.body]).to eq(["HTTP 400: token [redacted] refused", "token [redacted] refused"])
    end

    it "does not retry a failed session request" do
      issuer.reply(:get, "/session/", 503, { "detail" => "unavailable" })
      expect { auth.get_session(ACCESS_TOKEN) }.to raise_error(Didit::InternalServerError)
      issuer.reply(:delete, "/session/", 502, { "detail" => "bad gateway" })
      expect { auth.revoke_session(ACCESS_TOKEN) }.to raise_error(Didit::InternalServerError)
      expect(issuer.requests.map(&:method)).to eq(%i[get delete])
    end

    [
      { status: 200, body: "<html>", headers: { "Content-Type" => "text/html" } },
      { status: 200, body: '["not", "an", "object"]' },
      { status: 200, body: "" },
      { status: 204 }
    ].each do |response|
      it "refuses the success response #{response.inspect}" do
        issuer.route(:get, "/session/") { response }
        error = error_of { auth.get_session(ACCESS_TOKEN) }

        expect(error).to be_a(Didit::APIResponseValidationError)
        expect(error.message).to include("GET /session/")
        expect(error.status).to eq(response[:status])
      end
    end

    it "names the content type of a body that is not JSON, and redacts it" do
      issuer.route(:get, "/session/") do
        { status: 200, body: "<html>#{ACCESS_TOKEN}</html>", headers: { "Content-Type" => "text/html" } }
      end
      error = error_of { auth.get_session(ACCESS_TOKEN) }

      expect(error.message).to eq("Expected a JSON response from GET /session/, got text/html.")
      expect(error.body).to eq("<html>[redacted]</html>")
    end

    describe "transport errors" do
      {
        Errno::ECONNREFUSED => Didit::APIConnectionError,
        Errno::ECONNRESET => Didit::APIConnectionError,
        SocketError => Didit::APIConnectionError,
        EOFError => Didit::APIConnectionError,
        OpenSSL::SSL::SSLError => Didit::APIConnectionError,
        Net::OpenTimeout => Didit::APITimeoutError,
        Net::ReadTimeout => Didit::APITimeoutError,
        Errno::ETIMEDOUT => Didit::APITimeoutError
      }.each do |raised, expected|
        it "maps #{raised} to #{expected}, once, without the code" do
          issuer
          stub_request(:post, "#{ISSUER}/token/").to_raise(raised)
          error = error_of { auth.exchange_code(CODE, code_verifier: CODE_VERIFIER, redirect_uri: REDIRECT_URI) }

          expect(error.class).to eq(expected)
          expect([error.http_method, error.url]).to eq(["POST", "#{ISSUER}/token/"])
          expect(error.message).not_to include(CODE)
          expect(a_request(:post, "#{ISSUER}/token/")).to have_been_made.once
        end
      end

      it "maps a WebMock timeout to APITimeoutError, without retrying a GET" do
        issuer
        stub_request(:get, "#{ISSUER}/session/").to_timeout
        error = error_of { auth.get_session(ACCESS_TOKEN) }

        expect(error).to be_a(Didit::APITimeoutError)
        expect([error.http_method, error.url]).to eq(["GET", "#{ISSUER}/session/"])
        expect(a_request(:get, "#{ISSUER}/session/")).to have_been_made.once
      end

      it "maps a failed key fetch to a connection error and counts it" do
        issuer
        stub_request(:get, "#{ISSUER}#{JWKS}").to_raise(Errno::ECONNREFUSED)
        expect { auth.verify_access_token(key.sign(access_claims)) }.to raise_error(Didit::APIConnectionError)
        expect { auth.verify_access_token(key.sign(access_claims)) }
          .to raise_error(Didit::APIConnectionError, /less than a minute ago/)
        expect(a_request(:get, "#{ISSUER}#{JWKS}")).to have_been_made.once
      end
    end
  end
end
