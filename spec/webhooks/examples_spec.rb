# frozen_string_literal: true

require "rack"
require "stringio"
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
      let(:app) do
        ENV["DIDIT_WEBHOOK_SECRET"] = SECRET
        Rack::Builder.parse_file(File.join(EXAMPLES_DIR, "config.ru"))
      end
      let(:errors) { StringIO.new }

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
