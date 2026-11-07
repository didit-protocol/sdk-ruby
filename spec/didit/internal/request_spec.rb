# frozen_string_literal: true

RSpec.describe Didit::Internal::Request do
  include ApiHelpers

  let(:client) { generated_test_client(max_retries: 2) }
  let(:delays) { [] }
  let(:url) { "https://verification.didit.me/v3/session/s-1/decision/" }
  let(:ok) { { status: 200, body: '{"session_id":"s-1"}', headers: { "Content-Type" => "application/json" } } }

  before do
    allow(Didit::Internal::Util).to receive(:pause) { |seconds| delays << seconds }
  end

  def fetch_decision
    client.sessions.retrieve_decision("s-1")
  end

  def create_session
    client.sessions.create(workflow_id: "wf")
  end

  it "retries a GET on 5xx and gives up after max_retries" do
    stub = stub_request(:get, url).to_return(status: 503, body: '{"detail":"busy"}')
    expect { fetch_decision }.to raise_error(Didit::InternalServerError, "HTTP 503: busy")
    expect(stub).to have_been_requested.times(3)
    expect(delays.size).to eq(2)
  end

  it "succeeds when a retry works and reports the retries taken" do
    stub_request(:get, url).to_return({ status: 500 }, { status: 408 }, ok)
    raw = client.with_raw_response.sessions.retrieve_decision("s-1")
    expect(raw.retries_taken).to eq(2)
    expect(raw.parse.session_id).to eq("s-1")
  end

  [500, 503, 408].each do |status|
    it "never retries a POST after HTTP #{status}" do
      stub = stub_request(:post, "https://verification.didit.me/v3/session/").to_return(status: status)
      expect { create_session }.to raise_error(Didit::APIStatusError)
      expect(stub).to have_been_requested.once
    end
  end

  it "retries a POST after a 429" do
    stub = stub_request(:post, "https://verification.didit.me/v3/session/")
           .to_return({ status: 429, headers: { "Retry-After" => "1" } }, ok.merge(status: 201))
    create_session
    expect(stub).to have_been_requested.twice
    expect(delays).to eq([1.0])
  end

  it "never retries a PATCH after a 5xx" do
    stub = stub_request(:patch, %r{/v3/businesses/b-1/}).to_return(status: 503)
    expect { client.businesses.update("b-1") }.to raise_error(Didit::InternalServerError)
    expect(stub).to have_been_requested.once
  end

  it "retries DELETE and PUT like GET" do
    stub = stub_request(:delete, %r{/v3/biometric-templates/t-1/}).to_return({ status: 502 }, { status: 204 })
    client.biometric_templates.delete("t-1")
    expect(stub).to have_been_requested.twice
  end

  it "does not retry other 4xx" do
    stub = stub_request(:get, url).to_return(status: 404)
    expect { fetch_decision }.to raise_error(Didit::NotFoundError)
    expect(stub).to have_been_requested.once
  end

  it "honours max_retries: 0 and per-request max_retries" do
    stub = stub_request(:get, url).to_return(status: 503)
    expect { client.with_options(max_retries: 0).sessions.retrieve_decision("s-1") }
      .to raise_error(Didit::InternalServerError)
    expect(stub).to have_been_requested.once
    expect { client.sessions.retrieve_decision("s-1", request_options: { max_retries: 1 }) }
      .to raise_error(Didit::InternalServerError)
    expect(stub).to have_been_requested.times(3)
  end

  describe "connection failures" do
    it "retries any method when the connection failed before sending" do
      stub = stub_request(:post, "https://verification.didit.me/v3/session/")
             .to_raise(Errno::ECONNREFUSED).then.to_raise(SocketError).then.to_return(ok.merge(status: 201))
      create_session
      expect(stub).to have_been_requested.times(3)
    end

    it "treats a connect timeout as not sent" do
      stub = stub_request(:post, "https://verification.didit.me/v3/session/").to_timeout
      expect { create_session }.to raise_error(Didit::APITimeoutError, %r{Request timed out \(POST https://verification\.didit\.me/v3/session/\)})
      expect(stub).to have_been_requested.times(3)
    end

    it "does not retry a POST after a read timeout or a reset connection" do
      [Net::ReadTimeout, Errno::ECONNRESET, EOFError].each do |error|
        WebMock.reset!
        allow(Didit::Internal::Util).to receive(:pause)
        stub = stub_request(:post, "https://verification.didit.me/v3/session/").to_raise(error)
        expected = error == Net::ReadTimeout ? Didit::APITimeoutError : Didit::APIConnectionError
        expect { create_session }.to raise_error(expected) { |e| expect(e.http_method).to eq("POST") }
        expect(stub).to have_been_requested.once
      end
    end

    it "retries a GET after a read timeout and then raises APITimeoutError" do
      stub = stub_request(:get, url).to_raise(Net::ReadTimeout)
      expect { fetch_decision }.to raise_error(Didit::APITimeoutError) do |error|
        expect(error.url).to eq(url)
        expect(error.cause).to be_a(Didit::Internal::Transport::Failure)
      end
      expect(stub).to have_been_requested.times(3)
    end

    it "redacts credentials from connection error messages" do
      stub_request(:get, url).to_raise(IOError.new("broken pipe near #{ApiHelpers::TEST_API_KEY}"))
      expect { fetch_decision }.to raise_error(Didit::APIConnectionError) do |error|
        expect(error.message).not_to include(ApiHelpers::TEST_API_KEY)
        expect(error.message).to include("[redacted]")
      end
    end
  end

  describe "delays" do
    it "uses exponential backoff with full jitter, capped at 8 seconds" do
      allow(Kernel).to receive(:rand).and_return(0.999)
      expect((0..6).map { |n| described_class.backoff(n).round(2) })
        .to eq([0.5, 1.0, 2.0, 4.0, 7.99, 7.99, 7.99])
      allow(Kernel).to receive(:rand).and_return(0.0)
      expect(described_class.backoff(3)).to eq(0.0)
    end

    it "reads Retry-After as seconds or an HTTP date, capped at 60 and floored at 0" do
      now = Time.utc(2026, 1, 1, 0, 0, 0)
      retry_after = ->(value) { described_class.retry_after(value, now: now) }
      expect(retry_after.call("3")).to eq(3.0)
      expect(retry_after.call("1.5")).to eq(1.5)
      expect(retry_after.call("600")).to eq(60.0)
      expect(retry_after.call((now + 10).httpdate)).to eq(10.0)
      expect(retry_after.call((now - 10).httpdate)).to eq(0.0)
      expect(retry_after.call("soon")).to be_nil
      expect(retry_after.call(nil)).to be_nil
    end

    it "uses Retry-After for retried 5xx responses" do
      stub_request(:get, url).to_return({ status: 503, headers: { "Retry-After" => "2" } }, ok)
      fetch_decision
      expect(delays).to eq([2.0])
    end
  end
end
