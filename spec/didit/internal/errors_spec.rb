# frozen_string_literal: true

RSpec.describe Didit::Internal::Errors do
  include ApiHelpers

  def call_with(status:, body:, content_type: "application/json", headers: {})
    stub_api(status: status, body: body, content_type: content_type, headers: headers)
    generated_test_client.sessions.retrieve_decision("s-1")
  end

  {
    400 => Didit::BadRequestError, 401 => Didit::AuthenticationError, 403 => Didit::PermissionDeniedError,
    404 => Didit::NotFoundError, 409 => Didit::ConflictError, 422 => Didit::UnprocessableEntityError,
    429 => Didit::RateLimitError, 500 => Didit::InternalServerError, 502 => Didit::InternalServerError,
    503 => Didit::InternalServerError, 418 => Didit::APIStatusError, 302 => Didit::APIStatusError
  }.each do |status, klass|
    it "maps HTTP #{status} to #{klass}" do
      expect { call_with(status: status, body: '{"detail":"nope"}') }.to raise_error(klass) do |error|
        expect(error).to be_a(Didit::APIStatusError)
        expect(error).to be_a(Didit::DiditError)
        expect(error.status).to eq(status)
        expect(error.status_code).to eq(status)
        expect(error.body).to eq({ "detail" => "nope" })
        expect(error.message).to eq("HTTP #{status}: nope")
      end
    end
  end

  it "takes the detail from the usual keys" do
    {
      '{"message":"m"}' => "HTTP 400: m",
      '{"error":"e"}' => "HTTP 400: e",
      '{"error":"invalid_grant","error_description":"expired"}' => "HTTP 400: invalid_grant: expired",
      '{"email":["Enter a valid email."],"name":"too long"}' => "HTTP 400: email: Enter a valid email.; name: too long",
      '["first","second"]' => "HTTP 400: first; second",
      "{}" => "HTTP 400"
    }.each do |body, message|
      expect { call_with(status: 400, body: body) }.to raise_error(Didit::BadRequestError, message)
    end
  end

  it "keeps a text body and leaves long ones out of the message" do
    expect { call_with(status: 502, body: "Bad gateway", content_type: "text/plain") }
      .to raise_error(Didit::InternalServerError, "HTTP 502: Bad gateway") { |e| expect(e.body).to eq("Bad gateway") }
    expect { call_with(status: 502, body: "x" * 600, content_type: "text/html") }
      .to raise_error(Didit::InternalServerError, "HTTP 502")
    expect { call_with(status: 500, body: "", content_type: nil) }
      .to raise_error(Didit::InternalServerError, "HTTP 500") { |e| expect(e.body).to be_nil }
  end

  it "reads the request id from the usual headers and adds it to the message" do
    %w[X-Request-Id Request-Id X-Amzn-Requestid X-Correlation-Id].each do |name|
      expect { call_with(status: 404, body: '{"detail":"gone"}', headers: { name => "req-42" }) }
        .to raise_error(Didit::NotFoundError, "HTTP 404: gone (request id req-42)") do |error|
          expect(error.request_id).to eq("req-42")
          expect(error.headers[name.downcase]).to eq("req-42")
        end
    end
  end

  it "never includes the API key or the account token in the message or body" do
    echoed = %({"detail":"bad key #{ApiHelpers::TEST_API_KEY}","token":"#{ApiHelpers::TEST_ACCOUNT_TOKEN}"})
    expect { call_with(status: 403, body: echoed) }.to raise_error(Didit::PermissionDeniedError) do |error|
      expect(error.message).to eq("HTTP 403: bad key [redacted]")
      expect(error.body).to eq({ "detail" => "bad key [redacted]", "token" => "[redacted]" })
      expect(error.inspect).not_to include(ApiHelpers::TEST_API_KEY)
    end
  end

  it "raises APIResponseValidationError for a 2xx that is not JSON" do
    expect { call_with(status: 200, body: "<html>#{ApiHelpers::TEST_API_KEY}</html>", content_type: "text/html") }
      .to raise_error(Didit::APIResponseValidationError,
                      %r{Expected a JSON response from GET /v3/session/s-1/decision/}) do |e|
        expect(e.status).to eq(200)
        expect(e.body).to eq("<html>[redacted]</html>")
      end
  end

  it "raises APIResponseValidationError for invalid UTF-8" do
    expect { call_with(status: 200, body: "\xff\xfe".b) }.to raise_error(Didit::APIResponseValidationError)
  end

  it "builds status errors for invalid UTF-8 bodies without raising" do
    error = described_class.status_error(status: 500, headers: {}, raw_body: "\xffbad".b)
    expect(error.body).to eq("�bad")
  end

  it "keeps machine-readable reasons on the verification errors" do
    expect(Didit::WebhookVerificationError.new(:invalid_signature, "x").reason).to eq(:invalid_signature)
    expect(Didit::TokenVerificationError.new(:expired, "x").reason).to eq(:expired)
    expect(Didit::WebhookVerificationError::REASONS).to include(:missing_timestamp, :invalid_payload)
    expect(Didit::TokenVerificationError::REASONS).to include(:unknown_key, :invalid_audience)
  end

  it "has connection errors that carry the method and URL without the query" do
    error = Didit::APIConnectionError.new(http_method: "GET", url: "https://x/y")
    expect(error.message).to eq("Connection error.")
    expect(error.http_method).to eq("GET")
    expect(Didit::APITimeoutError.new.message).to eq("Request timed out.")
    expect(Didit::APITimeoutError.new).to be_a(Didit::APIConnectionError)
  end
end
