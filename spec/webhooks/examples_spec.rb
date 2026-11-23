# frozen_string_literal: true

require "rack"
require "stringio"
require "tmpdir"
require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "examples/webhooks" do
    include WebhookSpecs

    it "has the Rails, Sinatra and Rack receivers" do
      expect(Dir.children(EXAMPLES_DIR)).to contain_exactly(
        "rails_controller.rb", "sinatra_app.rb", "config.ru"
      )
    end

    Dir["#{EXAMPLES_DIR}/*"].each do |path|
      it "#{File.basename(path)} is valid Ruby that verifies the raw body with DIDIT_WEBHOOK_SECRET" do
        source = File.read(path, encoding: "UTF-8")
        expect { RubyVM::InstructionSequence.compile(source, path) }.not_to raise_error
        expect(source).to include('ENV.fetch("DIDIT_WEBHOOK_SECRET")', "Didit::Webhooks.verify(")
        expect(source).to include("WebhookVerificationError")
        expect(source).to match(/\bcase event\b/)
      end
    end

    describe "config.ru" do
      let(:app) { WebhookSpecs.rack_example }
      let(:errors) { StringIO.new }

      before { ENV["DIDIT_WEBHOOK_SECRET"] = SECRET } # read on every request; spec_helper clears it after

      def post(body, headers)
        env = headers.to_h { |name, value| ["HTTP_#{name.upcase.tr("-", "_")}", value] }
        Rack::MockRequest.new(app).post("/webhooks/didit", input: body, "rack.errors" => errors, **env)
      end

      def fresh_delivery(**fields)
        delivery(payload(timestamp: Time.now.to_i, **fields))
      end

      it "answers 200 to a signed delivery and dispatches on the event class" do
        response = post(*fresh_delivery(status: "Declined"))
        expect(response.status).to eq(200)
        expect(errors.string).to include("Didit session 11111111-2222-3333-4444-555555555555: Declined")
        expect(post(*fresh_delivery(webhook_type: "auth.user.created")).status).to eq(200)
        expect(errors.string).to include("auth.user.created event, unknown to this SDK version")
      end

      it "answers 401 with the reason to an unsigned or forged delivery" do
        body, headers = fresh_delivery
        expect(post(body, headers.slice("X-Timestamp"))).to have_attributes(status: 401, body: "missing_signature")
        expect(post(body.sub("Approved", "Declined"), headers))
          .to have_attributes(status: 401, body: "invalid_signature")
      end

      it "answers 400 with the reason to a stale or malformed delivery" do
        body, headers = delivery
        expect(post(body, headers)).to have_attributes(status: 400, body: "timestamp_out_of_tolerance")
        expect(post("not json", headers)).to have_attributes(status: 400, body: "invalid_payload")
      end

      it "answers 405 to other methods" do
        expect(Rack::MockRequest.new(app).get("/webhooks/didit").status).to eq(405)
      end
    end
  end
end

RSpec.describe "Bank connection example" do
  include ApiHelpers

  let(:recordings) { JSON.parse(File.read(File.join(__dir__, "fixtures/bank_deliveries.json"))) }
  let(:record) do
    recordings.fetch("deliveries").find { |r| JSON.parse(r.fetch("body"))["webhook_type"] == "bank.connection.created" }
  end
  let(:connection_id) { JSON.parse(record.fetch("body")).fetch("connection_id") }
  let(:client) { generated_test_client }
  let(:link) { Didit::Types::BankLink.new("id" => "example-link", "url" => "https://example.invalid/link") }
  let(:request) do
    app = Rack::Builder.parse_file(File.expand_path("../../examples/bank_connection.ru", __dir__))
    Rack::MockRequest.new(app)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      ENV["DIDIT_LINK_FILE"] = File.join(dir, "bank-link")
      example.run
    end
  end

  before do
    ENV["DIDIT_WEBHOOK_SECRET"] = recordings.fetch("secret")
    allow(Time).to receive(:now).and_return(Time.at(record.fetch("now")))
    bank = client.bank
    allow(Didit::Client).to receive(:new).and_return(client)
    allow(bank).to receive(:create_link).with(access: "ongoing", data: ["accounts"]).and_return(link)
  end

  def post_delivery(body = record.fetch("body"))
    headers = record.fetch("headers").transform_keys { |key| "HTTP_#{key.upcase.tr("-", "_")}" }
    request.post("/webhooks/didit", input: body, **headers)
  end

  it "delivers the link privately and reports the account count for the verified connection" do
    completed = Didit::Types::BankLink.new("connection_id" => connection_id)
    allow(client.bank).to receive(:get_link).with(link.id).and_return(completed)
    page = Struct.new(:items).new([])
    allow(client.bank).to receive(:list_accounts).with(connection_id, limit: 50).and_return(page)
    expect { expect(post_delivery.status).to eq(204) }.to output("Accounts on the first page: 0\n").to_stdout
    path = ENV.fetch("DIDIT_LINK_FILE")
    expect(File.read(path).chomp).to eq(link.url)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "ignores unrelated connections and rejects tampered or oversized deliveries before reading accounts" do
    other = Didit::Types::BankLink.new("connection_id" => "another-connection")
    allow(client.bank).to receive(:get_link).with(link.id).and_return(other)
    allow(client.bank).to receive(:list_accounts)
    expect(post_delivery.status).to eq(204)
    expect(post_delivery(record.fetch("body") + " ").status).to eq(204) # canonical V2 signature still matches
    expect(post_delivery(record.fetch("body").sub(connection_id, "tampered")).status).to eq(401)
    expect(post_delivery("x" * 65_537).status).to eq(413)
    expect(client.bank).not_to have_received(:list_accounts)
  end
end
