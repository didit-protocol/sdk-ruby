# frozen_string_literal: true

RSpec.describe Didit::Client do
  include ApiHelpers

  let(:decision) { '{"session_id":"s-1","status":"Approved"}' }

  describe "configuration" do
    it "reads the API key and ids from the environment" do
      ENV["DIDIT_API_KEY"] = "env-key"
      ENV["DIDIT_ORGANIZATION_ID"] = "env-org"
      ENV["DIDIT_APPLICATION_ID"] = " env-app "
      client = described_class.new
      expect(client.organization_id).to eq("env-org")
      expect(client.application_id).to eq("env-app")
      calls = stub_api(body: decision)
      client.sessions.retrieve_decision("s-1")
      expect(header(calls.requests.first, "x-api-key")).to eq("env-key")
    end

    it "prefers explicit options over the environment and treats empty values as unset" do
      ENV["DIDIT_API_KEY"] = "env-key"
      ENV["DIDIT_ORGANIZATION_ID"] = ""
      client = described_class.new(api_key: "explicit")
      expect(client.organization_id).to be_nil
      calls = stub_api(body: decision)
      client.sessions.retrieve_decision("s-1")
      expect(header(calls.requests.first, "x-api-key")).to eq("explicit")
    end

    it "has the documented defaults" do
      client = described_class.new(api_key: "k")
      expect(client.base_url).to eq("https://verification.didit.me")
      expect(client.account_base_url).to eq("https://apx.didit.me/auth/v2")
      expect(client.timeout).to eq(60.0)
      expect(client.max_retries).to eq(2)
    end

    it "strips a trailing slash from base URLs" do
      client = described_class.new(api_key: "k", base_url: "http://localhost:8080/")
      expect(client.base_url).to eq("http://localhost:8080")
    end

    it "rejects invalid options before any request" do
      expect { described_class.new(base_url: "ftp://x") }.to raise_error(Didit::ConfigurationError, /base_url/)
      expect { described_class.new(base_url: "https://user:pw@x") }.to raise_error(Didit::ConfigurationError)
      expect { described_class.new(base_url: "not a url") }.to raise_error(Didit::ConfigurationError)
      expect { described_class.new(timeout: 0) }.to raise_error(Didit::ConfigurationError, /timeout/)
      expect { described_class.new(timeout: "5") }.to raise_error(Didit::ConfigurationError, /timeout/)
      expect { described_class.new(max_retries: -1) }.to raise_error(Didit::ConfigurationError, /max_retries/)
      expect { described_class.new(default_headers: "x") }.to raise_error(Didit::ConfigurationError)
      expect { described_class.new(http_client: "x") }.to raise_error(Didit::ConfigurationError, /http_client/)
    end

    it "raises a ConfigurationError without an API key, before sending anything" do
      calls = stub_api(body: decision)
      expect { described_class.new.sessions.retrieve_decision("s-1") }
        .to raise_error(Didit::ConfigurationError, /DIDIT_API_KEY/)
      expect(calls.requests).to be_empty
    end

    it "raises a ConfigurationError for application-scoped methods without both ids" do
      calls = stub_api(body: "{}")
      client = described_class.new(api_key: "k", organization_id: "org")
      expect { client.cases.list }.to raise_error(Didit::ConfigurationError, /organization_id and application_id/)
      expect(calls.requests).to be_empty
    end

    it "fills application-scoped paths from the options" do
      calls = stub_api(body: '{"count":0,"next":null,"previous":null,"results":[]}')
      described_class.new(api_key: "k", organization_id: "org-1", application_id: "app-1").cases.list
      expect(calls.requests.first.uri.path).to eq("/v3/organization/org-1/application/app-1/cases/")
    end

    it "never shows the API key in inspect" do
      client = described_class.new(api_key: "secret-key-value")
      expect(client.inspect).not_to include("secret-key-value")
      expect(client.inspect).to include("api_key=[set]")
      expect(client.to_s).to eq(client.inspect)
    end
  end

  describe "headers" do
    it "sends the SDK headers and the API key" do
      calls = stub_api(body: decision)
      generated_test_client.sessions.retrieve_decision("s-1")
      request = calls.requests.first
      platform = Regexp.escape(RUBY_PLATFORM)
      expect(header(request, "User-Agent"))
        .to match(%r{\Adidit-ruby/#{Regexp.escape(Didit::VERSION)} \(#{RUBY_ENGINE} [0-9.]+; #{platform}\)\z})
      expect(header(request, "X-Didit-Client")).to eq("ruby/#{Didit::VERSION}")
      expect(header(request, "Accept")).to eq("application/json")
      expect(header(request, "x-api-key")).to eq(ApiHelpers::TEST_API_KEY)
    end

    it "merges default and per-request headers case-insensitively, nil removing one" do
      calls = stub_api(body: decision)
      client = generated_test_client(default_headers: { "x-custom" => "default", "X-Other" => "kept" })
      client.sessions.retrieve_decision(
        "s-1", request_options: { extra_headers: { "X-CUSTOM" => "override", "x-other" => nil } }
      )
      request = calls.requests.first
      expect(request.headers.keys.grep(/custom/i).size).to eq(1)
      expect(header(request, "x-custom")).to eq("override")
      expect(header(request, "x-other")).to be_nil
    end

    it "sends JSON bodies with a content type" do
      calls = stub_api(status: 201, body: '{"session_id":"s-1"}')
      generated_test_client.sessions.create(workflow_id: "wf-1")
      expect_json_body(calls.requests.first, { "workflow_id" => "wf-1" })
    end
  end

  describe "account methods" do
    it "use the account base URL and the Bearer token, never the API key" do
      calls = stub_api(body: "[]")
      generated_test_client.account.organizations.list
      request = calls.requests.first
      expect(calls.urls.first).to start_with("https://apx.didit.me/auth/v2/")
      expect(header(request, "Authorization")).to eq("Bearer #{ApiHelpers::TEST_ACCOUNT_TOKEN}")
      expect(header(request, "x-api-key")).to be_nil
    end

    it "send no credentials for login" do
      calls = stub_api(body: '{"access_token":"a"}')
      generated_test_client.account.login(email: "a@example.com", password: "pw")
      expect(header(calls.requests.first, "Authorization")).to be_nil
      expect(header(calls.requests.first, "x-api-key")).to be_nil
    end

    it "need an account token" do
      calls = stub_api(body: "[]")
      expect { described_class.new(api_key: "k").account.organizations.list }
        .to raise_error(Didit::ConfigurationError, /account token/)
      expect(calls.requests).to be_empty
    end
  end

  describe "#with_options" do
    it "returns a client with the changes and the same connections" do
      client = described_class.new(api_key: "k", organization_id: "org", timeout: 10)
      copy = client.with_options(timeout: 5, organization_id: nil, account_token: "tok")
      expect(copy.timeout).to eq(5.0)
      expect(copy.organization_id).to be_nil
      expect(client.timeout).to eq(10.0)
      expect(client.organization_id).to eq("org")
      expect(copy.send(:transport)).to equal(client.send(:transport))
      calls = stub_api(body: "[]")
      copy.account.organizations.list
      expect(header(calls.requests.first, "Authorization")).to eq("Bearer tok")
    end

    it "validates the new values" do
      expect { described_class.new(api_key: "k").with_options(max_retries: -2) }
        .to raise_error(Didit::ConfigurationError)
      expect { described_class.new(api_key: "k").with_options(bogus: 1) }.to raise_error(ArgumentError)
    end

    it "gives resources bound to the new client" do
      client = described_class.new(api_key: "old")
      calls = stub_api(body: decision)
      client.sessions # memoised on the original
      client.with_options(api_key: "new").sessions.retrieve_decision("s-1")
      expect(header(calls.requests.first, "x-api-key")).to eq("new")
    end
  end

  describe "request options" do
    it "adds extra query and body values" do
      calls = stub_api(status: 201, body: "{}")
      generated_test_client.sessions.create(
        workflow_id: "wf", request_options: { extra_query: { "debug" => "1" }, extra_body: { "beta_flag" => true } }
      )
      request = calls.requests.first
      expect(request.uri.query).to eq("debug=1")
      expect(JSON.parse(request.body)).to eq({ "workflow_id" => "wf", "beta_flag" => true })
    end

    it "rejects unknown keys and wrong types" do
      expect { generated_test_client.sessions.retrieve_decision("s", request_options: { retries: 1 }) }
        .to raise_error(Didit::ConfigurationError, /Unknown request_options :retries/)
      expect { generated_test_client.sessions.retrieve_decision("s", request_options: "x") }
        .to raise_error(Didit::ConfigurationError, /must be a Hash/)
      expect { generated_test_client.sessions.retrieve_decision("s", request_options: { timeout: -1 }) }
        .to raise_error(Didit::ConfigurationError, /timeout/)
    end
  end

  describe "path parameters" do
    it "percent-encodes them as one path segment" do
      calls = stub_api(body: decision)
      generated_test_client.sessions.retrieve_decision("a/b c?d#e%fé")
      expect(calls.requests.first.uri.path).to eq("/v3/session/a%2Fb%20c%3Fd%23e%25f%C3%A9/decision/")
    end

    it "refuses values that would change the path" do
      calls = stub_api(body: decision)
      ["", ".", ".."].each do |value|
        expect { generated_test_client.sessions.retrieve_decision(value) }
          .to raise_error(Didit::ConfigurationError, /Path parameter sessionId/)
      end
      expect { generated_test_client.sessions.retrieve_decision(nil) }.to raise_error(Didit::ConfigurationError)
      expect { generated_test_client.sessions.retrieve_decision(1.5) }.to raise_error(Didit::ConfigurationError)
      expect(calls.requests).to be_empty
    end

    it "accepts integers and symbols" do
      calls = stub_api(body: decision)
      generated_test_client.sessions.retrieve_decision(42)
      expect(calls.requests.first.uri.path).to eq("/v3/session/42/decision/")
    end
  end

  describe "query and body encoding" do
    it "leaves out omitted and nil query values, repeats arrays and writes booleans" do
      calls = stub_api(body: '{"count":0,"results":[]}')
      generated_test_client.sessions.list(status: %w[Approved Declined], vendor_data: nil,
                                          is_kyc_to_be_reviewed: true, limit: 5)
      pairs = URI.decode_www_form(URI(calls.urls.first).query).sort
      expect(pairs).to eq([%w[is_kyc_to_be_reviewed true], %w[limit 5], %w[status Approved], %w[status Declined]])
    end

    it "sends nil as JSON null, leaves out omitted keywords and serialises Time and symbol keys" do
      calls = stub_api(status: 201, body: "{}")
      generated_test_client.sessions.create(
        workflow_id: "wf", vendor_data: nil, metadata: { plan: :gold, at: Time.utc(2026, 1, 2, 3, 4, 5) }
      )
      expect(JSON.parse(calls.requests.first.body)).to eq(
        "workflow_id" => "wf", "vendor_data" => nil,
        "metadata" => { "plan" => "gold", "at" => "2026-01-02T03:04:05.000000Z" }
      )
    end

    it "refuses a file in a JSON-only operation" do
      expect { generated_test_client.sessions.create(workflow_id: "wf", metadata: Didit::FilePart.new("x")) }
        .to raise_error(Didit::ConfigurationError, /file/)
    end

    it "raises ArgumentError for unknown or missing keywords, like any Ruby method" do
      expect { generated_test_client.sessions.create(workflow_id: "wf", bogus: 1) }.to raise_error(ArgumentError)
      expect { generated_test_client.sessions.create }.to raise_error(ArgumentError, /workflow_id/)
    end
  end

  describe "#request" do
    it "calls any path and returns the parsed JSON for an untyped response" do
      calls = stub_api(body: '{"ok":true}')
      result = generated_test_client.request(:get, "/v3/anything/{id}/", path_params: { "id" => "x" }, response: :any)
      expect(result).to eq({ "ok" => true })
      expect(calls.requests.first.uri.path).to eq("/v3/anything/x/")
    end

    it "returns nil for 204 and for empty bodies" do
      stub_api(status: 204, body: nil, content_type: nil)
      expect(generated_test_client.request(:delete, "/v3/x/", response: :any)).to be_nil
    end

    it "picks the type by status" do
      stub_api(status: 202, body: '{"job_id":"j"}')
      result = generated_test_client.sessions.batch_delete(delete_all: true)
      expect(result).to be_a(Didit::Types::SessionsBatchDeleteResponse202)
    end
  end

  describe "#deprecated" do
    it "warns once per method in the :deprecated category" do
      client = generated_test_client
      allow(Kernel).to receive(:warn)
      name = "test.deprecated_#{rand(1_000_000)}"
      2.times { client.deprecated(name, "Use x instead.") }
      expect(Kernel).to have_received(:warn).with("Didit: #{name} is deprecated. Use x instead.", category: :deprecated)
                                            .once
    end
  end

  describe "#close" do
    it "can be called at any time" do
      expect(generated_test_client.close).to be_nil
    end
  end
end
