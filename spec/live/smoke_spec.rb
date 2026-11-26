# frozen_string_literal: true

require "securerandom"

# Live smoke tests against a Didit sandbox application (docs/DESIGN.md section 11).
# They run only when DIDIT_SANDBOX_API_KEY is set, never in CI, and create nothing that
# costs money beyond sandbox sessions:
#
#   DIDIT_SANDBOX_API_KEY=... [DIDIT_SANDBOX_WORKFLOW_ID=...] bundle exec rspec --tag live
RSpec.describe "Didit sandbox", :live do
  let(:client) do
    Didit::Client.new(api_key: ENV.fetch("DIDIT_SANDBOX_API_KEY"),
                      base_url: ENV.fetch("DIDIT_SANDBOX_BASE_URL", Didit::Client::DEFAULT_BASE_URL))
  end

  before { WebMock.allow_net_connect! }
  after { WebMock.disable_net_connect! }

  it "lists sessions and workflows" do
    page = client.sessions.list(limit: 1)
    expect(page).to be_a(Didit::Page)
    expect(page.total_count).to be_a(Integer)
    expect(client.workflows.list).not_to be_nil
  end

  it "creates a session and reads its decision" do
    workflow_id = ENV.fetch("DIDIT_SANDBOX_WORKFLOW_ID", nil)
    skip "set DIDIT_SANDBOX_WORKFLOW_ID to create a sandbox session" unless workflow_id

    session = client.sessions.create(workflow_id: workflow_id, vendor_data: "sdk-ruby-smoke-#{SecureRandom.hex(4)}")
    expect(session.session_id).to be_a(String)
    expect(session.url).to start_with("https://")
    decision = client.sessions.retrieve_decision(session.session_id)
    expect(decision.session_id).to eq(session.session_id)
    expect(decision.status).to be_a(String)
  end

  it "raises NotFoundError for an unknown session" do
    expect { client.sessions.retrieve_decision(SecureRandom.uuid) }.to raise_error(Didit::NotFoundError)
  end

  it "rejects a wrong API key with an error that does not contain it" do
    wrong = Didit::Client.new(api_key: "sdk-ruby-smoke-wrong-key", base_url: client.base_url)
    expect { wrong.sessions.list(limit: 1) }.to raise_error(Didit::APIStatusError) do |error|
      expect(error.status).to eq(401).or eq(403)
      expect(error.message).not_to include("sdk-ruby-smoke-wrong-key")
    end
  end
end
