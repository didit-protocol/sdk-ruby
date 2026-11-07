# frozen_string_literal: true

require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "Didit::Webhooks.verify_parsed" do
    include WebhookSpecs

    let(:data) { payload(metadata: { "plan" => "pro", "seats" => 3, "ratio" => 0.25 }, decision: nil) }
    let(:signed) { delivery(data, previous: PREVIOUS) }
    let(:headers) { signed[1] }
    let(:parsed) { JSON.parse(signed[0]) }

    def verify_parsed(value = parsed, hdrs = headers, secret = SECRET, now: NOW, **options)
      Didit::Webhooks.verify_parsed(value, hdrs, secret, now: now, **options)
    end

    it "verifies X-Signature-V2 over the parsed body" do
      event = verify_parsed
      expect(event).to be_a(Didit::Webhooks::StatusUpdatedEvent)
      expect(event).to have_attributes(verified_by: "X-Signature-V2", body_authenticated?: true, status: "Approved")
    end

    it "accepts Symbol keys, nested ones too" do
      symbolized = Didit::Model.symbolize(parsed)
      expect(symbolized.keys).to all(be_a(Symbol))
      event = verify_parsed(symbolized)
      expect(event.verified_by).to eq("X-Signature-V2")
      expect(event[:metadata]).to eq({ "plan" => "pro", "seats" => 3, "ratio" => 0.25 })
    end

    it "verifies X-Signature-V2-Previous with the previous secret" do
      expect(verify_parsed(parsed, headers, PREVIOUS).verified_by).to eq("X-Signature-V2-Previous")
      expect(verify_parsed(parsed, headers.slice("X-Signature-V2-Previous"), [SECRET, PREVIOUS]).verified_by)
        .to eq("X-Signature-V2-Previous")
    end

    it "accepts integral floats the framework may have produced" do
      expect(verify_parsed(parsed.merge("metadata" => { "plan" => "pro", "seats" => 3.0, "ratio" => 0.25 })))
        .to be_a(Didit::Webhooks::Event)
    end

    it "cannot check the other signatures" do
      expect { verify_parsed(parsed, headers.slice("X-Signature", "X-Signature-Simple", "X-Signature-Previous")) }
        .to raise_error(verification_error(:invalid_signature), /verify_parsed can check only X-Signature-V2/)
      expect(reason_of { verify_parsed(parsed, headers.slice("X-Timestamp")) }).to eq(:missing_signature)
    end

    it "rejects a changed payload" do
      expect(reason_of { verify_parsed(parsed.merge("status" => "Declined")) }).to eq(:invalid_signature)
      expect(reason_of { verify_parsed(parsed.merge("extra" => 1)) }).to eq(:invalid_signature)
    end

    it "applies the timestamp rules" do
      expect(reason_of { verify_parsed(now: NOW + 301) }).to eq(:timestamp_out_of_tolerance)
      expect(reason_of { verify_parsed(parsed, headers.merge("X-Timestamp" => "1")) }).to eq(:timestamp_mismatch)
      expect(reason_of { verify_parsed(parsed.except("timestamp")) }).to eq(:missing_timestamp)
      expect(verify_parsed(parsed, headers, SECRET, now: NOW + 600, tolerance: 600)).to be_a(Didit::Webhooks::Event)
    end

    it "checks the configuration first" do
      expect { verify_parsed("not a hash", headers, "") }.to raise_error(Didit::ConfigurationError)
      expect { verify_parsed([], headers, SECRET, tolerance: -1) }.to raise_error(Didit::ConfigurationError)
    end

    [JSON.generate(WebhookSpecs.payload), [WebhookSpecs.payload], nil, 1].each do |value|
      it "is invalid_payload for a #{value.class}" do
        expect { verify_parsed(value) }.to raise_error(verification_error(:invalid_payload), /Hash/)
      end
    end

    it "is invalid_payload for data that is not JSON" do
      deep = (1..10_000).reduce({}) { |inner, _| { "a" => inner } }
      looped = { "timestamp" => NOW }
      looped["self"] = looped
      [
        parsed.merge("x" => Float::NAN), parsed.merge("x" => [Float::INFINITY]), parsed.merge("x" => :symbol),
        parsed.merge("x" => Time.at(0)), parsed.merge("x" => "\xFF".b), parsed.merge(1 => 2),
        parsed.merge("x" => deep), looped
      ].each do |value|
        expect(reason_of { verify_parsed(value) }).to eq(:invalid_payload)
      end
    end

    it "leaves the caller's Hash as it was" do
      value = parsed
      before = Marshal.load(Marshal.dump(value))
      verify_parsed(value)
      expect(value).to eq(before)
      expect(value).not_to be_frozen
    end
  end
end
