# frozen_string_literal: true

RSpec.describe Didit::Internal::Log do
  include ApiHelpers

  let(:logger_class) do
    Class.new do
      attr_reader :lines

      def initialize
        @lines = []
      end

      def debug(progname = nil)
        @lines << [progname, yield]
      end
    end
  end

  before do
    stub_request(:get, %r{/v3/session/s-1/decision/})
      .to_return(status: 200, body: '{"session_id":"s-1"}', headers: { "X-Request-Id" => "req-7" })
  end

  it "prints method, path, status, duration and request id to stderr with DIDIT_LOG=debug" do
    ENV["DIDIT_LOG"] = "DEBUG"
    expect { generated_test_client.sessions.retrieve_decision("s-1", include: "events") }
      .to output(%r{\A\[didit\] GET /v3/session/s-1/decision/ -> 200 in \d+ ms \(request id req-7\)\n\z}).to_stderr
  end

  it "never prints the query, body, headers or API key" do
    ENV["DIDIT_LOG"] = "debug"
    expect { generated_test_client.sessions.retrieve_decision("s-1", include: "events") }
      .not_to output(/events|test-key|session_id/).to_stderr
  end

  it "is silent by default" do
    expect { generated_test_client.sessions.retrieve_decision("s-1") }.not_to output.to_stderr
  end

  it "writes to a logger when one is given, including retries" do
    allow(Didit::Internal::Util).to receive(:pause)
    stub_request(:get, %r{/v3/session/s-2/decision/}).to_return({ status: 503 }, { status: 200, body: "{}" })
    logger = logger_class.new
    generated_test_client(logger: logger, max_retries: 1).sessions.retrieve_decision("s-2")
    messages = logger.lines.map(&:last)
    expect(logger.lines.map(&:first)).to all(eq("didit"))
    expect(messages[0]).to match(%r{GET /v3/session/s-2/decision/ -> 503 in \d+ ms \(request id -\)})
    expect(messages[1]).to match(%r{GET /v3/session/s-2/decision/: HTTP 503; retrying in \d\.\d\d s \(1 retries left\)})
    expect(messages[2]).to include("-> 200")
  end

  it "logs connection failures before a retry" do
    allow(Didit::Internal::Util).to receive(:pause)
    stub_request(:get, %r{/v3/session/s-3/decision/}).to_raise(Errno::ECONNREFUSED).then.to_return(body: "{}")
    logger = logger_class.new
    generated_test_client(logger: logger, max_retries: 1).sessions.retrieve_decision("s-3")
    expect(logger.lines.first.last).to include("Errno::ECONNREFUSED; retrying")
  end
end
