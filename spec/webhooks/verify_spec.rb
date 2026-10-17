# frozen_string_literal: true

require "stringio"
require_relative "webhooks_helper"

module WebhookSpecHelpers
  RSpec.describe "Didit::Webhooks.verify" do # rubocop:disable RSpec/DescribeClass -- specs are grouped by area
    include WebhookSpecHelpers
    extend WebhookSpecHelpers

    let(:data) { payload(vendor_data: "user-1", workflow_version: 3, metadata: { "name" => "José", "score" => 87.0 }) }
    let(:signed) { delivery(data) }
    let(:body) { signed[0] }
    let(:headers) { signed[1] }

    def verify(raw = body, hdrs = headers, secret = SECRET, now: NOW, **options)
      Didit::Webhooks.verify(raw, hdrs, secret, now: now, **options)
    end

    def reason_of(&block)
      block.call
      nil
    rescue Didit::WebhookVerificationError => e
      e.reason
    end

    describe "a valid delivery" do
      it "returns the typed event, verified by X-Signature" do
        event = verify
        expect(event).to be_a(Didit::Webhooks::StatusUpdatedEvent)
        expect(event).to have_attributes(verified_by: "X-Signature", body_authenticated?: true, status: "Approved",
                                         vendor_data: "user-1", workflow_version: 3, environment: "sandbox",
                                         timestamp: NOW, webhook_type: "status.updated")
        expect(event[:metadata]).to eq({ "name" => "José", "score" => 87.0 })
      end

      it "reads the body bytes as UTF-8 whatever the String's encoding" do
        expect(verify(body.b).verified_by).to eq("X-Signature")
        expect(verify(body.dup.force_encoding(Encoding::ISO_8859_1)).verified_by).to eq("X-Signature")
        expect(verify(body.freeze).verified_by).to eq("X-Signature")
      end

      it "verifies a re-encoded body with X-Signature-V2" do
        reencoded = JSON.pretty_generate(JSON.parse(body), ascii_only: true).sub("87.0", "8.7e1")
        expect(reencoded).to include("\\u00e9", "8.7e1")
        expect(verify(reencoded).verified_by).to eq("X-Signature-V2")
      end

      it "uses the current time by default" do
        fresh = payload(timestamp: Time.now.to_i)
        raw, hdrs = delivery(fresh)
        expect(Didit::Webhooks.verify(raw, hdrs, SECRET)).to be_a(Didit::Webhooks::StatusUpdatedEvent)
      end
    end

    describe "configuration errors, raised before anything else" do
      [nil, "", [], [""], [SECRET, ""], [SECRET, nil], 5, :whsec_test_symbol, { secret: SECRET }].each do |secret|
        it "rejects the secret #{secret.inspect}" do
          expect { verify(body, headers, secret) }.to raise_error(Didit::ConfigurationError)
          expect { verify("not json", {}, secret) }.to raise_error(Didit::ConfigurationError)
        end
      end

      it "names DIDIT_WEBHOOK_SECRET when the secret is nil" do
        expect { verify(body, headers, nil) }.to raise_error(Didit::ConfigurationError, /DIDIT_WEBHOOK_SECRET/)
      end

      [-1, -0.5, Float::NAN, "300", nil, true, Rational(1, 2)].each do |tolerance|
        it "rejects the tolerance #{tolerance.inspect}" do
          expect { verify("not json", tolerance: tolerance) }.to raise_error(Didit::ConfigurationError)
        end
      end

      ["1760702400", Float::NAN, Float::INFINITY, Time.at(NOW)].each do |now|
        it "rejects now: #{now.inspect}" do
          expect { verify("not json", now: now) }.to raise_error(Didit::ConfigurationError)
        end
      end

      [nil, 5, "X-Signature: abc"].each do |hdrs|
        it "rejects headers #{hdrs.inspect}" do
          expect { verify("not json", hdrs) }.to raise_error(Didit::ConfigurationError, /headers/)
        end
      end

      it "is a DiditError" do
        expect(Didit::ConfigurationError.ancestors).to include(Didit::DiditError)
        expect(Didit::WebhookVerificationError.ancestors).to include(Didit::DiditError)
      end
    end

    describe "the timestamp" do
      it "accepts exactly the tolerance in both directions and rejects one second more" do
        expect(verify(now: NOW + 300)).to be_a(Didit::Webhooks::Event)
        expect(verify(now: NOW - 300)).to be_a(Didit::Webhooks::Event)
        expect(reason_of { verify(now: NOW + 301) }).to eq(:timestamp_out_of_tolerance)
        expect(reason_of { verify(now: NOW - 301) }).to eq(:timestamp_out_of_tolerance)
        expect(reason_of { verify(now: NOW + 300.5) }).to eq(:timestamp_out_of_tolerance)
        expect(verify(now: NOW + 300.0)).to be_a(Didit::Webhooks::Event)
      end

      it "honours the tolerance option" do
        expect(verify(now: NOW + 600, tolerance: 600)).to be_a(Didit::Webhooks::Event)
        expect(verify(now: NOW, tolerance: 0)).to be_a(Didit::Webhooks::Event)
        expect(reason_of { verify(now: NOW + 1, tolerance: 0) }).to eq(:timestamp_out_of_tolerance)
        expect(verify(now: NOW + 10**9, tolerance: Float::INFINITY)).to be_a(Didit::Webhooks::Event)
        expect(verify(now: NOW + 1.5, tolerance: 1.5)).to be_a(Didit::Webhooks::Event)
      end

      {
        "no timestamp" => payload.except("timestamp"),
        "a string" => payload(timestamp: NOW.to_s),
        "a float" => payload(timestamp: NOW.to_f),
        "true" => payload(timestamp: true),
        "null" => payload(timestamp: nil),
        "an object" => payload(timestamp: { "value" => NOW })
      }.each do |description, data|
        it "is missing_timestamp for #{description}" do
          raw, hdrs = delivery(data.merge("timestamp" => data["timestamp"]))
          expect(reason_of { verify(raw, hdrs) }).to eq(:missing_timestamp)
        end
      end

      it "is missing_timestamp for 1760702400.0 written in the body" do
        raw = body.sub("\"timestamp\":#{NOW}", "\"timestamp\":#{NOW}.0")
        expect(reason_of { verify(raw, headers.except("X-Timestamp")) }).to eq(:missing_timestamp)
      end

      it "treats absurdly long timestamps as out of tolerance, quickly" do
        huge = "1#{"0" * 100_000}"
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [huge, "-#{huge}", "1#{"0" * 15}"].each do |digits|
          raw = "{\"timestamp\":#{digits},\"webhook_type\":\"status.updated\"}"
          hdrs = { "X-Signature" => "0" * 64, "X-Signature-V2" => "0" * 64 }
          expect(reason_of { verify(raw, hdrs) }).to eq(:timestamp_out_of_tolerance)
          expect(reason_of { verify(raw, hdrs.merge("X-Timestamp" => digits)) }).to eq(:timestamp_out_of_tolerance)
        end
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      end

      it "allows a missing X-Timestamp" do
        expect(verify(body, headers.except("X-Timestamp")).verified_by).to eq("X-Signature")
        expect(verify(body, headers.merge("X-Timestamp" => "  ")).verified_by).to eq("X-Signature")
      end

      ["+1760702400", "0001760702400", " 1760702400 ", "-0#{NOW}".delete_prefix("-"), NOW].each do |value|
        it "accepts X-Timestamp #{value.inspect}" do
          expect(verify(body, headers.merge("X-Timestamp" => value))).to be_a(Didit::Webhooks::Event)
        end
      end

      ["1760702405", "soon", "1_760_702_400", "1760702400.0", "1.7607024e9", "0x68F1E3C0",
       "١٧٦٠٧٠٢٤٠٠", "1760702400, 1760702400", "17607 02400",
       "#{"0" * 40}1760702400", "-1760702400"].each do |value|
        it "is timestamp_mismatch for X-Timestamp #{value.inspect}" do
          expect(reason_of { verify(body, headers.merge("X-Timestamp" => value)) }).to eq(:timestamp_mismatch)
        end
      end
    end

    describe "the order of the checks" do
      it "reports the timestamp before the signature" do
        bad = headers.merge("X-Signature" => "0" * 64, "X-Signature-V2" => "0" * 64)
        expect(reason_of { verify(body, bad, now: NOW + 1000) }).to eq(:timestamp_out_of_tolerance)
        expect(reason_of { verify(body, {}, now: NOW + 1000) }).to eq(:timestamp_out_of_tolerance)
        expect(reason_of { verify(body, bad.merge("X-Timestamp" => "1"), now: NOW + 1000) }).to eq(:timestamp_mismatch)
      end

      it "reports the payload before the timestamp" do
        expect(reason_of { verify("[]", headers, now: NOW + 1000) }).to eq(:invalid_payload)
        expect(reason_of { verify("{\"x\":1}", {}) }).to eq(:missing_timestamp)
      end
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
        { "X-Signature" => "X-Signature", "X-Signature-V2" => "X-Signature-V2",
          "X-Signature-Previous" => "X-Signature", "X-Signature-V2-Previous" => "X-Signature-V2" }.each do |name, source|
          expect(verify(body, { name => headers[source] }).verified_by).to eq(name)
        end
      end

      it "tries X-Signature first, then X-Signature-V2, then the -Previous variants" do
        wrong = "0" * 64
        expect(verify(body, headers.merge("X-Signature" => wrong)).verified_by).to eq("X-Signature-V2")
        only_previous = { "X-Signature" => wrong, "X-Signature-V2" => wrong, "X-Signature-Previous" => headers["X-Signature"],
                          "X-Signature-V2-Previous" => headers["X-Signature-V2"] }
        expect(verify(body, only_previous).verified_by).to eq("X-Signature-Previous")
        expect(verify(body, only_previous.merge("X-Signature-Previous" => wrong)).verified_by).to eq("X-Signature-V2-Previous")
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
        expect(OpenSSL).to have_received(:fixed_length_secure_compare).with(headers["X-Signature"], headers["X-Signature"])
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
          expect(message).not_to include(SECRET, "whsec_test_other", *headers.values_at("X-Signature", "X-Signature-V2"))
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
        expect(verify(raw, simple_previous, PREVIOUS, allow_simple: true).verified_by).to eq("X-Signature-Simple-Previous")
        expect(verify(raw, hdrs, [PREVIOUS, SECRET]).verified_by).to eq("X-Signature-Previous")
      end

      it "uses the secret's UTF-8 bytes as the key" do
        secret = "whsec_test_clé"
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
          expect(verify(raw, hdrs.slice("X-Signature-Simple"), allow_simple: true).verified_by).to eq("X-Signature-Simple")
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

    describe "hostile bodies" do
      nested = "{\"timestamp\":#{NOW},\"x\":#{"[" * 10_000}#{"]" * 10_000}}"
      deep_objects = "#{"{\"a\":" * 10_000}1#{"}" * 10_000}"
      {
        "an array" => "[]", "a number" => "1", "a string" => "\"x\"", "null" => "null", "empty" => "",
        "truncated" => "{", "not JSON" => "not json", "trailing data" => "{\"timestamp\":1} x",
        "a BOM" => "\xEF\xBB\xBF{\"timestamp\":#{NOW}}", "10000 nested arrays" => nested,
        "10000 nested objects" => deep_objects, "101 nested arrays" => "{\"x\":#{"[" * 100}#{"]" * 100}}",
        "invalid UTF-8" => "{\"timestamp\":#{NOW},\"x\":\"\xFF\"}".b, "a lone high surrogate" => '{"x":"\ud800"}',
        "a lone low surrogate" => '{"x":"\udc00"}', "a reversed pair" => '{"x":"\udc00\ud800"}',
        "NaN" => "{\"timestamp\":NaN}", "Infinity" => "{\"timestamp\":#{NOW},\"x\":Infinity}",
        "-Infinity" => "{\"x\":-Infinity}", "1e400" => "{\"timestamp\":#{NOW},\"x\":1e400}",
        "-1e400" => "{\"timestamp\":#{NOW},\"x\":-1e400}", "UTF-16" => "{\"timestamp\":1}".encode(Encoding::UTF_16LE),
        "a control character" => "{\"x\":\"\u0001\"}"
      }.each do |description, raw|
        it "is invalid_payload for #{description}" do
          hdrs = { "X-Signature" => sign(SECRET, raw.b), "X-Signature-V2" => "0" * 64 }
          expect(reason_of { verify(raw, hdrs, allow_simple: true) }).to eq(:invalid_payload)
        end
      end

      [nil, 42, StringIO.new("{}"), { "timestamp" => NOW }].each do |raw|
        it "is invalid_payload for a #{raw.class} body" do
          expect { verify(raw) }.to raise_error(verification_error(:invalid_payload), /String/)
        end
      end

      it "keeps the last value of a repeated key, like Python" do
        raw = body.sub("\"status\":\"Approved\"", "\"status\":\"Declined\",\"status\":\"Approved\"")
        hdrs = { "X-Signature-V2" => headers["X-Signature-V2"] }
        expect(verify(raw, hdrs)).to have_attributes(status: "Approved", verified_by: "X-Signature-V2")
      end
    end
  end
end
