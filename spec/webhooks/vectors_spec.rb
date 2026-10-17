# frozen_string_literal: true

require_relative "webhooks_helper"

# Every vector of openapi/webhook-vectors.json, produced by the backend's own signing code.
module WebhookSpecs
  RSpec.describe "Didit::Webhooks vectors" do
    include WebhookSpecs

    let(:tolerance) { WebhookSpecs.vectors_document.fetch("tolerance_seconds") }

    it "covers every outcome" do
      expect(WebhookSpecs.vectors_document["vectors"].map { |v| v["expect"] }.uniq).to contain_exactly(
        "valid", "valid_only_with_allow_simple", "invalid_signature", "missing_signature",
        "timestamp_out_of_tolerance", "timestamp_mismatch"
      )
    end

    WebhookSpecs.vectors_document.fetch("vectors").each do |vector|
      describe vector["name"] do
        let(:body) { vector["body"] }
        let(:headers) { vector["headers"] }
        let(:secrets) { [vector["secret"], vector["previous_secret"]].compact }
        let(:now) { vector["now"] }

        def verify(body = self.body, headers = self.headers, secret = secrets, **options)
          Didit::Webhooks.verify(body, headers, secret, now: now, tolerance: tolerance, **options)
        end

        if vector["name"] == "tampered_body"
          it "has a canonical_v2 recorded before the body was altered" do
            expect(Didit::Webhooks.canonical_json(JSON.parse(body))).not_to eq(vector["canonical_v2"])
          end
        else
          it "rebuilds canonical_v2 byte for byte" do
            canonical = Didit::Webhooks.canonical_json(JSON.parse(body))
            expect(canonical.b).to eq(vector["canonical_v2"].b)
            expect(canonical.encoding).to eq(Encoding::UTF_8)
          end
        end

        case vector["expect"]
        when "valid"
          it "verifies" do
            event = verify
            expect(event).to be_a(Didit::Webhooks::Event)
            expect(event.body_authenticated?).to be(true)
            expect(event.webhook_type).to eq(JSON.parse(body)["webhook_type"])
            expect(event.to_h).to eq(Didit::Model.symbolize(JSON.parse(body)))
          end

          it "verifies with X-Signature-V2 alone on a re-encoded body" do
            v2_only = headers.slice("X-Signature-V2", "X-Signature-V2-Previous", "X-Timestamp")
            pretty = JSON.pretty_generate(JSON.parse(body))
            expect(pretty).not_to eq(body)
            expect(verify(pretty, v2_only).verified_by).to start_with("X-Signature-V2")
          end

          it "verifies the parsed body with verify_parsed" do
            event = Didit::Webhooks.verify_parsed(JSON.parse(body), headers, secrets, now: now, tolerance: tolerance)
            expect(event.verified_by).to start_with("X-Signature-V2")
            expect(event.body_authenticated?).to be(true)
          end

          if vector["previous_secret"]
            it "verifies with each secret of the rotation alone" do
              expect(verify(body, headers, vector["secret"]).verified_by).to eq("X-Signature")
              expect(verify(body, headers, vector["previous_secret"]).verified_by).to eq("X-Signature-Previous")
              expect(verify(body, headers, [vector["previous_secret"], vector["secret"]]).body_authenticated?).to be(true)
            end
          end
        when "valid_only_with_allow_simple"
          it "fails without allow_simple and verifies, body unauthenticated, with it" do
            expect { verify }.to raise_error(verification_error(:invalid_signature))
            event = verify(allow_simple: true)
            expect(event.verified_by).to eq("X-Signature-Simple")
            expect(event.body_authenticated?).to be(false)
          end
        else
          it "fails with #{vector["expect"]}" do
            expect { verify }.to raise_error(verification_error(vector["expect"].to_sym))
          end
        end
      end
    end
  end
end
