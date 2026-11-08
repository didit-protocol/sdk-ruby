# frozen_string_literal: true

require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "Didit::Webhooks.verify signatures" do
    include WebhookSpecs
    extend WebhookSpecs

    let(:data) { payload(vendor_data: "user-1", workflow_version: 3, metadata: { "name" => "José", "score" => 87.0 }) }
    let(:signed) { delivery(data) }
    let(:body) { signed[0] }
    let(:headers) { signed[1] }

    def verify(raw = body, hdrs = headers, secret = SECRET, now: NOW, **options)
      Didit::Webhooks.verify(raw, hdrs, secret, now: now, **options)
    end

    describe "signatures" do
      it "is missing_signature without any signature header" do
        expect(reason_of { verify(body, headers.slice("X-Timestamp")) }).to eq(:missing_signature)
        empty = { "X-Signature" => "", "X-Signature-V2" => " ", "X-Signature-Simple" => [""], "X-Timestamp" => NOW }
        expect(reason_of { verify(body, empty) }).to eq(:missing_signature)
      end

      it "is invalid_signature when nothing matches" do
        tampered = body.sub("Approved", "Declined")
        expect(reason_of { verify(tampered) }).to eq(:invalid_signature)
        expect(reason_of { verify(body, headers, "whsec_test_other") }).to eq(:invalid_signature)
      end

      it "checks each header on its own" do
        sources = { "X-Signature" => "X-Signature", "X-Signature-V2" => "X-Signature-V2",
                    "X-Signature-Previous" => "X-Signature", "X-Signature-V2-Previous" => "X-Signature-V2" }
        sources.each do |name, source|
          expect(verify(body, { name => headers[source] }).verified_by).to eq(name)
        end
      end

      it "tries X-Signature first, then X-Signature-V2, then the -Previous variants" do
        wrong = "0" * 64
        expect(verify(body, headers.merge("X-Signature" => wrong)).verified_by).to eq("X-Signature-V2")
        only_previous = { "X-Signature" => wrong, "X-Signature-V2" => wrong,
                          "X-Signature-Previous" => headers["X-Signature"],
                          "X-Signature-V2-Previous" => headers["X-Signature-V2"] }
        expect(verify(body, only_previous).verified_by).to eq("X-Signature-Previous")
        expect(verify(body, only_previous.merge("X-Signature-Previous" => wrong)).verified_by)
          .to eq("X-Signature-V2-Previous")
      end

      it "only considers 64 lowercase hex characters" do
        good = headers["X-Signature"]
        ["A" * 64, good.upcase, "g" * 64, good[0, 63], "#{good}0", " #{good[0, 63]}", good.sub(/./, "é")].each do |bad|
          hdrs = { "X-Signature" => bad, "X-Signature-V2" => bad, "X-Signature-Simple" => bad }
          expect(reason_of { verify(body, hdrs, allow_simple: true) }).to eq(:invalid_signature)
        end
        expect(good).to match(/\A[0-9a-f]{64}\z/)
      end

      it "compares in constant time" do
        allow(OpenSSL).to receive(:fixed_length_secure_compare).and_call_original
        verify
        signature = headers["X-Signature"]
        expect(OpenSSL).to have_received(:fixed_length_secure_compare).with(signature, signature)
      end

      it "builds the canonical JSON only when an X-Signature-V2 is needed" do
        signed # the spec's own signing builds it too
        allow(Didit::Webhooks::CanonicalJson).to receive(:dump).and_call_original
        verify
        verify(body, headers.merge("X-Signature" => "0" * 64, "X-Signature-V2" => "not-hex"), allow_simple: true)
        expect(Didit::Webhooks::CanonicalJson).not_to have_received(:dump)
        verify(body, headers.merge("X-Signature" => "0" * 64))
        expect(Didit::Webhooks::CanonicalJson).to have_received(:dump).once
      end

      it "never puts the secret or a signature in an error message" do
        messages = [
          -> { verify(body.sub("Approved", "Declined")) }, -> { verify(body, headers, "whsec_test_other") },
          -> { verify(body, headers.slice("X-Signature-Simple")) }, -> { verify(body, headers, now: 0) },
          -> { verify(body, headers.merge("X-Timestamp" => "1")) }, -> { verify("{", headers) }
        ].map do |call|
          call.call
        rescue Didit::WebhookVerificationError => e
          e.message
        end
        expect(messages.size).to eq(6)
        messages.each do |message|
          signatures = headers.values_at("X-Signature", "X-Signature-V2")
          expect(message).not_to include(SECRET, "whsec_test_other", *signatures)
        end
      end
    end

    describe "secret rotation" do
      it "accepts a list of secrets, in any order" do
        raw, hdrs = delivery(data, secret: PREVIOUS)
        expect(reason_of { verify(raw, hdrs, SECRET) }).to eq(:invalid_signature)
        expect(verify(raw, hdrs, [SECRET, PREVIOUS]).verified_by).to eq("X-Signature")
        expect(verify(raw, hdrs, [PREVIOUS, SECRET]).verified_by).to eq("X-Signature")
      end

      it "accepts the -Previous signatures with the previous secret" do
        raw, hdrs = delivery(data, previous: PREVIOUS)
        expect(verify(raw, hdrs, PREVIOUS).verified_by).to eq("X-Signature-Previous")
        expect(verify(raw, hdrs.except("X-Signature-Previous"), PREVIOUS).verified_by).to eq("X-Signature-V2-Previous")
        simple_previous = hdrs.slice("X-Signature-Simple-Previous")
        expect(verify(raw, simple_previous, PREVIOUS, allow_simple: true).verified_by)
          .to eq("X-Signature-Simple-Previous")
        expect(verify(raw, hdrs, [PREVIOUS, SECRET]).verified_by).to eq("X-Signature-Previous")
      end

      it "uses the secret's UTF-8 bytes as the key" do
        secret = "#{SECRET}é"
        raw, hdrs = delivery(data, secret: secret)
        expect(verify(raw, hdrs, secret.encode(Encoding::UTF_16LE)).verified_by).to eq("X-Signature")
        expect(verify(raw, hdrs, secret.b).verified_by).to eq("X-Signature")
      end
    end

    describe "X-Signature-Simple (deprecated)" do
      let(:simple_only) { headers.slice("X-Signature-Simple", "X-Timestamp") }

      it "counts only with allow_simple, and then the body is not authenticated" do
        expect { verify(body, simple_only) }.to raise_error(verification_error(:invalid_signature), /allow_simple/)
        event = verify(body, simple_only, allow_simple: true)
        expect(event).to have_attributes(verified_by: "X-Signature-Simple", body_authenticated?: false)
      end

      it "prefers a full-body signature" do
        expect(verify(allow_simple: true).verified_by).to eq("X-Signature")
      end

      it "takes only true or false for allow_simple, so a string from the environment cannot turn it on" do
        ["false", "true", 0, 1, nil, "yes"].each do |value|
          expect { verify(body, simple_only, allow_simple: value) }
            .to raise_error(Didit::ConfigurationError, /allow_simple must be true or false/)
        end
      end

      it "signs only the envelope" do
        tampered = body.sub("José", "Mallory")
        expect(verify(tampered, simple_only, allow_simple: true).body_authenticated?).to be(false)
        expect(reason_of { verify(body.sub("Approved", "Declined"), simple_only, allow_simple: true) })
          .to eq(:invalid_signature)
      end

      {
        "a null session_id (None)" => payload(session_id: nil),
        "no session_id" => payload(webhook_type: "transaction.status.updated").except("session_id"),
        "a boolean status (True)" => payload(status: true),
        "an integer status" => payload(status: 7)
      }.each do |description, data|
        it "formats #{description} like the backend's str()" do
          raw, hdrs = delivery(data)
          event = verify(raw, hdrs.slice("X-Signature-Simple"), allow_simple: true)
          expect(event.verified_by).to eq("X-Signature-Simple")
        end
      end

      it "formats a float field with Python repr" do
        raw = body.sub("\"status\":\"Approved\"", "\"status\":1e-05")
        message = "#{NOW}:#{data["session_id"]}:1e-05:status.updated"
        hdrs = { "X-Signature-Simple" => sign(SECRET, message) }
        expect(verify(raw, hdrs, allow_simple: true).verified_by).to eq("X-Signature-Simple")
      end

      it "never matches when a signed field is an object or an array" do
        [{ "a" => 1 }, [1]].each do |status|
          raw = JSON.generate(payload(status: status))
          hdrs = { "X-Signature-Simple" => sign(SECRET, "#{NOW}:#{data["session_id"]}:#{status}:status.updated") }
          expect(reason_of { verify(raw, hdrs, allow_simple: true) }).to eq(:invalid_signature)
        end
      end
    end
  end
end
