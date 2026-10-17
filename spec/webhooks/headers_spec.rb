# frozen_string_literal: true

require "net/http"
require "rack"
require "stringio"
require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "Didit::Webhooks.verify headers" do
    include WebhookSpecs

    let(:signed) { delivery }
    let(:body) { signed[0] }
    let(:headers) { signed[1] }
    let(:signature) { headers["X-Signature"] }

    def verify(hdrs, **options)
      Didit::Webhooks.verify(body, hdrs, SECRET, now: NOW, **options)
    end

    it "matches names in any case" do
      expect(verify(headers.transform_keys(&:downcase)).verified_by).to eq("X-Signature")
      expect(verify(headers.transform_keys(&:upcase)).verified_by).to eq("X-Signature")
      expect(verify({ "x-SIGNATURE-v2" => headers["X-Signature-V2"], "x-timestamp" => NOW.to_s }).verified_by)
        .to eq("X-Signature-V2")
    end

    it "accepts Symbol names" do
      expect(verify({ "X-Signature": signature }).verified_by).to eq("X-Signature")
    end

    it "reads a Rack env (Rails request.headers and Sinatra request.env yield the same names)" do
      env = Rack::MockRequest.env_for("/webhooks/didit", method: "POST", input: body)
      headers.each { |name, value| env["HTTP_#{name.upcase.tr("-", "_")}"] = value }
      expect(env["rack.input"]).to respond_to(:read)
      expect(verify(env).verified_by).to eq("X-Signature")
      expect(verify(env.slice("HTTP_X_SIGNATURE_V2", "HTTP_X_TIMESTAMP")).verified_by).to eq("X-Signature-V2")
    end

    it "reads [name, value] pairs, Rack::Headers and Net::HTTPHeader" do
      expect(verify(headers.to_a).verified_by).to eq("X-Signature")
      expect(verify(Rack::Headers.new.merge!(headers)).verified_by).to eq("X-Signature")
      request = Net::HTTP::Post.new("/")
      headers.each { |name, value| request[name] = value }
      expect(verify(request).verified_by).to eq("X-Signature")
    end

    it "reads Array values, as Rack 3 may give them" do
      expect(verify({ "X-Signature" => ["", "0" * 64, signature], "X-Timestamp" => [NOW.to_s] }).verified_by)
        .to eq("X-Signature")
    end

    it "considers every comma-separated part, as a proxy that joins repeated headers writes them" do
      expect(verify({ "X-Signature" => "#{"0" * 64}, #{signature}" }).verified_by).to eq("X-Signature")
      expect(verify({ "X-Signature" => "#{signature},#{"1" * 64}" }).verified_by).to eq("X-Signature")
      request = Net::HTTP::Post.new("/")
      request.add_field("X-Signature", "f" * 64)
      request.add_field("X-Signature", signature)
      expect(verify(request).verified_by).to eq("X-Signature")
    end

    it "reads the same header under names in different cases" do
      expect(verify({ "X-Signature" => "0" * 64, "x-signature" => signature }).verified_by).to eq("X-Signature")
    end

    it "treats empty values as absent" do
      empty = { "X-Signature" => "", "X-Signature-V2" => "  ", "X-Signature-Previous" => [], "X-Signature-Simple" => ",",
                "X-Timestamp" => "" }
      expect(reason_of { verify(empty) }).to eq(:missing_signature)
      expect(verify(headers.merge("X-Timestamp" => "")).verified_by).to eq("X-Signature")
    end

    it "folds _ into - only for the HTTP_ form" do
      expect(reason_of { verify({ "X_SIGNATURE" => signature }) }).to eq(:missing_signature)
      expect(verify({ "http_x_signature" => signature }).verified_by).to eq("X-Signature")
    end

    it "ignores values that are not text, such as the Rack input stream" do
      hdrs = { "X-Signature" => signature, "HTTP_X_SIGNATURE_V2" => StringIO.new("x"), "X-Timestamp" => NOW,
               "rack.input" => StringIO.new(body), 42 => "x", nil => nil }
      expect(verify(hdrs).verified_by).to eq("X-Signature")
    end

    it "survives header values that are not valid UTF-8" do
      hdrs = { "X-Signature" => (+"\xFF\xFE,").force_encoding(Encoding::UTF_8), "X-Timestamp" => "\xFF".b }
      expect(reason_of { verify(hdrs.merge("X-Timestamp" => NOW.to_s)) }).to eq(:invalid_signature)
      expect(reason_of { verify(hdrs) }).to eq(:timestamp_mismatch)
    end
  end
end
