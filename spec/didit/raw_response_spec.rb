# frozen_string_literal: true

RSpec.describe Didit::RawResponse do
  include ApiHelpers

  it "exposes status, headers, request id, body and the parsed result" do
    stub_request(:post, "https://verification.didit.me/v3/session/")
      .to_return(status: 201, body: '{"session_id":"s-1"}',
                 headers: { "Content-Type" => "application/json", "X-Request-Id" => "req-1" })
    client = generated_test_client
    raw = client.with_raw_response.sessions.create(workflow_id: "wf")
    expect(raw).to be_a(described_class)
    expect(raw.status).to eq(201)
    expect(raw.status_code).to eq(201)
    expect(raw.headers["x-request-id"]).to eq("req-1")
    expect(raw.request_id).to eq("req-1")
    expect(raw.body).to eq('{"session_id":"s-1"}')
    expect(raw.retries_taken).to eq(0)
    expect(raw.elapsed).to be >= 0
    expect(raw.parse).to be_a(Didit::Types::SessionsCreateResponse)
    expect(raw.parse).to equal(raw.parse)
    expect(raw.inspect).to include("status=201")
  end

  it "is a mode of the client that with_options keeps" do
    client = generated_test_client
    expect(client.raw_response?).to be(false)
    expect(client.with_raw_response.raw_response?).to be(true)
    expect(client.with_raw_response.with_options(timeout: 1).raw_response?).to be(true)
  end

  it "keeps a streamed binary body out of the raw response" do
    stub_request(:get, %r{/v3/session/s-1/generate-pdf/}).to_return(body: "%PDF",
                                                                    headers: { "Content-Type" => "application/pdf" })
    chunks = []
    raw = generated_test_client.with_raw_response.sessions.generate_pdf("s-1") { |c| chunks << c }
    expect(chunks.join).to eq("%PDF")
    expect(raw.body).to be_nil
    expect(raw.parse).to be_nil
  end

  it "raises status errors like the parsed call does" do
    stub_request(:get, %r{/v3/session/s-1/decision/}).to_return(status: 404, body: '{"detail":"x"}')
    expect { generated_test_client.with_raw_response.sessions.retrieve_decision("s-1") }
      .to raise_error(Didit::NotFoundError)
  end
end
