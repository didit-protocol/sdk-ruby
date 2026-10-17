# frozen_string_literal: true

require "net/http"

RSpec.describe Didit::Internal::Transport do
  let(:servers) { [] }
  let(:decision) { '{"session_id":"s-1"}' }

  # These tests talk to a server on 127.0.0.1 through the real net/http (WebMock off), so
  # keep-alive, dropped connections, timeouts and streaming behave as in production.
  around do |example|
    WebMock.disable!
    example.run
  ensure
    servers.each(&:stop)
    WebMock.enable!
  end

  before { allow(Didit::Internal::Util).to receive(:pause) }

  def serve(&handler)
    LocalServer.new(&handler).tap { |s| servers << s }
  end

  def client_for(server, **options)
    Didit::Client.new(api_key: "local-key", base_url: server.url, max_retries: 2, **options)
  end

  it "keeps the connection open between requests" do
    server = serve { { body: decision } }
    client = client_for(server)
    3.times { client.sessions.retrieve_decision("s-1") }
    expect(server.connections).to eq(1)
    expect(server.received.map(&:target)).to all(eq("/v3/session/s-1/decision/"))
  end

  it "opens a new connection after Connection: close" do
    server = serve { { body: decision, headers: { "Connection" => "close" } } }
    client = client_for(server)
    2.times { client.sessions.retrieve_decision("s-1") }
    expect(server.connections).to eq(2)
  end

  it "sends the request line, headers and body net/http builds" do
    server = serve { { status: 201, body: '{"session_id":"s-9"}' } }
    session = client_for(server).sessions.create(workflow_id: "wf-1", vendor_data: "user-42")
    expect(session.session_id).to eq("s-9")
    request = server.received.first
    expect(request.verb).to eq("POST")
    expect(request.target).to eq("/v3/session/")
    expect(request.headers["x-api-key"]).to eq("local-key")
    expect(request.headers["content-type"]).to eq("application/json")
    expect(JSON.parse(request.body)).to eq({ "workflow_id" => "wf-1", "vendor_data" => "user-42" })
  end

  it "does not retry a POST whose connection dropped after sending" do
    server = serve { { drop: true } }
    expect { client_for(server).sessions.create(workflow_id: "wf") }.to raise_error(Didit::APIConnectionError)
    expect(server.received.size).to eq(1)
  end

  it "retries a GET whose connection dropped" do
    server = serve { |_, index| index < 3 ? { drop: true } : { body: decision } }
    expect(client_for(server).sessions.retrieve_decision("s-1").session_id).to eq("s-1")
    expect(server.received.size).to eq(3)
  end

  it "raises APITimeoutError on a read timeout, without retrying a POST" do
    server = serve { { delay: 1.0, body: "{}" } }
    expect { client_for(server, timeout: 0.2).sessions.create(workflow_id: "wf") }
      .to raise_error(Didit::APITimeoutError)
    expect(server.received.size).to eq(1)
  end

  it "retries a refused connection for every method, then raises APIConnectionError" do
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    client = Didit::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 2)
    expect { client.sessions.create(workflow_id: "wf") }.to raise_error(Didit::APIConnectionError, /ECONNREFUSED/)
    expect(Didit::Internal::Util).to have_received(:pause).twice
  end

  it "streams a binary body to a block and returns bytes without one" do
    pdf = "%PDF-1.7\n#{"x" * 50_000}".b
    server = serve { { headers: { "Content-Type" => "application/pdf" }, chunks: pdf.scan(/.{1,8192}/m) } }
    client = client_for(server)
    expect(client.sessions.generate_pdf("s-1")).to eq(pdf)
    chunks = []
    expect(client.sessions.generate_pdf("s-1") { |chunk| chunks << chunk }).to be_nil
    expect(chunks.join.b).to eq(pdf)
    expect(chunks.size).to be > 1
    expect(server.received.first.headers["accept"]).to eq("application/pdf, application/json")
  end

  it "raises the status error for a failed binary request instead of streaming the error body" do
    server = serve { { status: 404, body: '{"detail":"no session"}' } }
    chunks = []
    expect { client_for(server).sessions.generate_pdf("s-1") { |chunk| chunks << chunk } }
      .to raise_error(Didit::NotFoundError, "HTTP 404: no session")
    expect(chunks).to be_empty
  end

  it "never follows a redirect, so the API key never reaches another origin" do
    other = serve { { body: decision } }
    server = serve { { status: 302, headers: { "Location" => "#{other.url}/steal" }, body: "" } }
    expect { client_for(server).sessions.retrieve_decision("s-1") }
      .to raise_error(Didit::APIStatusError) { |e| expect(e.status).to eq(302) }
    expect(other.received).to be_empty
  end

  it "builds connections with the http_client factory" do
    server = serve { { body: decision } }
    hosts = []
    factory = lambda do |uri|
      hosts << "#{uri.host}:#{uri.port}"
      Net::HTTP.new(uri.host, uri.port)
    end
    client = client_for(server, http_client: factory)
    2.times { client.sessions.retrieve_decision("s-1") }
    expect(hosts).to eq(["127.0.0.1:#{server.port}"])
  end

  it "refuses an http_client that does not return Net::HTTP" do
    server = serve { { body: decision } }
    client = client_for(server, http_client: ->(_) { Object.new })
    expect { client.sessions.retrieve_decision("s-1") }.to raise_error(Didit::ConfigurationError, /Net::HTTP/)
  end

  it "does not reuse a parent's connections after fork" do
    server = serve { { body: decision } }
    client = client_for(server)
    client.sessions.retrieve_decision("s-1")
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    client.sessions.retrieve_decision("s-1")
    expect(server.connections).to eq(2)
  end

  it "closes idle connections on close" do
    server = serve { { body: decision } }
    client = client_for(server)
    client.sessions.retrieve_decision("s-1")
    client.close
    client.sessions.retrieve_decision("s-1")
    expect(server.connections).to eq(2)
  end

  it "keeps working from many threads" do
    server = serve { { body: decision } }
    client = client_for(server)
    results = Array.new(8) { Thread.new { Array.new(5) { client.sessions.retrieve_decision("s-1").session_id } } }
                   .flat_map(&:value)
    expect(results).to all(eq("s-1"))
    expect(server.connections).to be <= Didit::Internal::Transport::MAX_IDLE + 8
  end
end
