# frozen_string_literal: true

RSpec.describe Didit::Internal::Request do
  include ApiHelpers

  let(:client) { generated_test_client(max_retries: 2) }
  let(:delays) { [] }
  let(:session_url) { "https://verification.didit.me/v3/session/" }
  let(:ok) { { status: 201, body: '{"session_id":"s-1"}', headers: { "Content-Type" => "application/json" } } }
  let(:opts) { { idempotency_key: "key-1" } }

  before do
    allow(Didit::Internal::Util).to receive(:pause) { |seconds| delays << seconds }
  end

  def create_session(request_options = opts)
    client.sessions.create(workflow_id: "wf", request_options: request_options)
  end

  def json_error(status, code, headers = {})
    { status: status, body: JSON.generate("detail" => "x", "code" => code),
      headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  describe "the header" do
    it "is sent on POST, PATCH, PUT and DELETE" do
      stub_request(:any, /.*/).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      create_session
      client.businesses.update("b-1", request_options: opts)
      client.biometric_templates.delete("t-1", request_options: opts)
      client.request(:put, "/v3/things/", request_options: opts)
      %i[post patch delete put].each do |verb|
        expect(a_request(verb, /.*/).with(headers: { "Idempotency-Key" => "key-1" })).to have_been_made.once
      end
    end

    it "is left out of GET and HEAD" do
      stub_request(:any, /.*/).to_return(status: 200, body: '{"session_id":"s-1"}')
      client.sessions.retrieve_decision("s-1", request_options: opts)
      expect(a_request(:get, /.*/).with { |req| req.headers.keys.none? { |k| k.casecmp?("Idempotency-Key") } })
        .to have_been_made.once
      config = client.instance_variable_get(:@config)
      prepared = described_class.prepare(config, :head, "/v3/things/",
                                         described_class.options(config, opts))
      expect(prepared.headers.keys.map(&:downcase)).not_to include("idempotency-key")
    end

    it "is not sent when no key is given" do
      stub = stub_request(:post, session_url).to_return(ok)
      create_session(nil)
      expect(stub.with { |req| req.headers.keys.none? { |k| k.casecmp?("Idempotency-Key") } }).to have_been_requested
    end

    it "is not accepted by the constructor or with_options" do
      expect { Didit::Client.new(api_key: "k", idempotency_key: "a") }.to raise_error(ArgumentError, /idempotency_key/)
      expect { client.with_options(idempotency_key: "a") }.to raise_error(ArgumentError)
    end

    it "is never invented by the SDK" do
      stub_request(:post, session_url).to_return(ok)
      create_session(nil)
      expect(WebMock).not_to have_requested(:post, session_url).with(headers: { "Idempotency-Key" => /.*/ })
    end
  end

  describe "validation" do
    [["", "empty"], ["a" * 256, "256 characters"], [nil, "nil"], [123, "an Integer"],
     [:key, "a Symbol"]].each do |value, label|
      it "rejects #{label} before sending anything" do
        stub = stub_request(:post, session_url).to_return(ok)
        expect { create_session(idempotency_key: value) }.to raise_error(Didit::ConfigurationError, /idempotency_key/)
        expect(stub).not_to have_been_requested
      end
    end

    it "accepts 1 and 255 characters" do
      stub_request(:post, session_url).to_return(ok)
      expect { create_session(idempotency_key: "a") }.not_to raise_error
      expect { create_session(idempotency_key: "a" * 255) }.not_to raise_error
    end
  end

  describe "retries" do
    it "retries a POST with a key on 5xx with the same key every time" do
      stub = stub_request(:post, session_url).with(headers: { "Idempotency-Key" => "key-1" })
                                             .to_return({ status: 503 }, { status: 500 }, ok)
      create_session
      expect(stub).to have_been_requested.times(3)
    end

    it "retries a POST with a key after a read timeout" do
      stub = stub_request(:post, session_url).with(headers: { "Idempotency-Key" => "key-1" })
                                             .to_raise(Net::ReadTimeout).then.to_return(ok)
      create_session
      expect(stub).to have_been_requested.twice
    end

    it "retries a PATCH with a key on 5xx" do
      stub = stub_request(:patch, %r{/v3/businesses/b-1/}).with(headers: { "Idempotency-Key" => "key-1" })
                                                          .to_return({ status: 503 }, { status: 200, body: "{}" })
      client.businesses.update("b-1", request_options: opts)
      expect(stub).to have_been_requested.twice
    end

    it "gives up after max_retries" do
      stub = stub_request(:post, session_url).to_return(status: 503)
      expect { create_session }.to raise_error(Didit::InternalServerError)
      expect(stub).to have_been_requested.times(3)
    end

    it "still never retries a POST without a key" do
      stub = stub_request(:post, session_url).to_return(status: 503)
      expect { create_session(nil) }.to raise_error(Didit::InternalServerError)
      expect(stub).to have_been_requested.once
      WebMock.reset!
      stub = stub_request(:post, session_url).to_raise(Net::ReadTimeout)
      expect { create_session(nil) }.to raise_error(Didit::APITimeoutError)
      expect(stub).to have_been_requested.once
    end

    it "retries a key-in-progress 409 honouring Retry-After" do
      stub = stub_request(:post, session_url)
             .to_return(json_error(409, "idempotency_key_in_progress", "Retry-After" => "1"), ok)
      create_session
      expect(stub).to have_been_requested.twice
      expect(delays).to eq([1.0])
    end

    it "raises a key-reused 409 at once" do
      stub = stub_request(:post, session_url).to_return(json_error(409, "idempotency_key_reused"))
      expect { create_session }.to raise_error(Didit::ConflictError)
      expect(stub).to have_been_requested.once
    end

    it "raises any other 409, and an unparsable 409, at once" do
      stub = stub_request(:post, session_url).to_return(json_error(409, "other"), { status: 409, body: "nope" })
      2.times { expect { create_session }.to raise_error(Didit::ConflictError) }
      expect(stub).to have_been_requested.twice
    end

    it "does not retry a key-in-progress 409 without a key" do
      stub = stub_request(:post, session_url).to_return(json_error(409, "idempotency_key_in_progress"))
      expect { create_session(nil) }.to raise_error(Didit::ConflictError)
      expect(stub).to have_been_requested.once
    end
  end

  describe "an operation with a generated header parameter" do
    let(:aml_url) { "https://verification.didit.me/v3/aml/" }

    it "sends one header with the option's value" do
      stub_request(:post, aml_url).to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      client.aml.screen(full_name: "A B", idempotency_key: "from-param",
                        request_options: { idempotency_key: "from-option" })
      matcher = have_requested(:post, aml_url).with do |req|
        req.headers.select { |k, _| k.casecmp?("Idempotency-Key") }.values == ["from-option"]
      end
      expect(WebMock).to matcher
    end

    it "retries a POST that carries the key as a parameter" do
      stub = stub_request(:post, aml_url).to_return({ status: 503 }, { status: 200, body: "{}" })
      client.aml.screen(full_name: "A B", idempotency_key: "from-param")
      expect(stub).to have_been_requested.twice
    end
  end

  describe "the effective key" do
    let(:aml_url) { "https://verification.didit.me/v3/aml/" }
    let(:json) { { "Content-Type" => "application/json" } }

    def key_values(req)
      req.headers.select { |k, _| k.casecmp?("Idempotency-Key") }
    end

    it "treats a lower-case raw header as the key: one header, retried on 5xx" do
      stub = stub_request(:post, session_url).to_return({ status: 503 }, ok)
      create_session(extra_headers: { "idempotency-key" => "raw-1" })
      expect(stub).to have_been_requested.twice
      expect(a_request(:post, session_url).with { |req| key_values(req).values == ["raw-1"] }).to have_been_made.twice
    end

    it "validates a raw header value" do
      stub = stub_request(:post, session_url).to_return(ok)
      ["", "a" * 256].each do |value|
        expect { create_session(extra_headers: { "Idempotency-Key" => value }) }
          .to raise_error(Didit::ConfigurationError, /idempotency_key/)
      end
      expect(stub).not_to have_been_requested
    end

    it "validates the generated parameter" do
      stub = stub_request(:post, aml_url).to_return(status: 200, body: "{}", headers: json)
      ["", "a" * 256, 5].each do |value|
        expect { client.aml.screen(full_name: "A B", idempotency_key: value) }
          .to raise_error(Didit::ConfigurationError, /idempotency_key/)
      end
      expect(stub).not_to have_been_requested
    end

    it "makes a POST with a valid generated parameter retryable" do
      stub = stub_request(:post, aml_url).to_return({ status: 503 }, { status: 200, body: "{}", headers: json })
      client.aml.screen(full_name: "A B", idempotency_key: "p-1")
      expect(stub).to have_been_requested.twice
    end

    it "sends one header with the option's value when option, raw header and parameter are all given" do
      stub_request(:post, aml_url).to_return(status: 200, body: "{}", headers: json)
      client.aml.screen(full_name: "A B", idempotency_key: "param",
                        request_options: { extra_headers: { "idempotency-key" => "raw" }, idempotency_key: "opt" })
      expect(a_request(:post, aml_url).with { |req| key_values(req).to_a == [%w[Idempotency-Key opt]] })
        .to have_been_made.once
    end

    it "treats an absent parameter as no key" do
      stub = stub_request(:post, aml_url).to_return(status: 503)
      expect { client.aml.screen(full_name: "A B") }.to raise_error(Didit::InternalServerError)
      expect(stub).to have_been_requested.once
    end

    it "ignores a client-wide default Idempotency-Key header" do
      default = generated_test_client(max_retries: 2, default_headers: { "idempotency-key" => "default" })
      stub = stub_request(:post, session_url).with { |req| key_values(req).empty? }.to_return(status: 503)
      expect { default.sessions.create(workflow_id: "wf") }.to raise_error(Didit::InternalServerError)
      expect(stub).to have_been_requested.once
      WebMock.reset!
      stub_request(:post, session_url).to_return(ok)
      default.sessions.create(workflow_id: "wf", request_options: opts)
      expect(a_request(:post, session_url).with { |req| key_values(req).values == ["key-1"] }).to have_been_made.once
    end

    it "sends the key only on the allow-listed methods" do
      config = client.instance_variable_get(:@config)
      options = described_class.options(config, opts)
      %i[options get head].each do |verb|
        prepared = described_class.prepare(config, verb, "/v3/things/", options,
                                           headers: { "Idempotency-Key" => "param" })
        expect(prepared.headers.keys.map(&:downcase)).not_to include("idempotency-key")
        expect(described_class.keyed?(prepared)).to be(false)
      end
    end

    it "retries the in-progress 409 for a keyed PUT and a keyed DELETE, and raises it without a key" do
      busy = json_error(409, "idempotency_key_in_progress", "Retry-After" => "1")
      calls = {
        put: ->(request_options) { client.request(:put, "/v3/things/", request_options: request_options) },
        delete: ->(request_options) { client.biometric_templates.delete("t-1", request_options: request_options) }
      }
      calls.each do |verb, call|
        WebMock.reset!
        delays.clear
        stub = stub_request(verb, %r{/v3/}).to_return(busy, { status: 200, body: "{}", headers: json })
        call.call(opts)
        expect(stub).to have_been_requested.twice
        expect(delays).to eq([1.0])

        WebMock.reset!
        stub = stub_request(verb, %r{/v3/}).to_return(busy)
        expect { call.call(nil) }.to raise_error(Didit::ConflictError)
        expect(stub).to have_been_requested.once
      end
    end

    it "raises a 409 with a key and a non-JSON body at once" do
      stub = stub_request(:post, session_url).to_return(status: 409, body: "<html>")
      expect { create_session }.to raise_error(Didit::ConflictError)
      expect(stub).to have_been_requested.once
    end
  end

  it "never logs the key" do
    ENV["DIDIT_LOG"] = "debug"
    stub_request(:post, session_url).to_return({ status: 503 }, ok)
    clean = satisfy { |text| text.include?("retrying") && !text.include?("secret-key-xyz") }
    expect { create_session(idempotency_key: "secret-key-xyz") }.to output(clean).to_stderr
  end
end
