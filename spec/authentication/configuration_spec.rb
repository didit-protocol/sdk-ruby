# frozen_string_literal: true

require "net/http"
require_relative "authentication_helper"

module AuthenticationHelper
  RSpec.describe Didit::Authentication, "configuration" do
    include AuthenticationHelper

    describe ".from_publishable_key" do
      it "reads the issuer a live or test key carries" do
        sandbox = "https://acme-0001.sandbox.auth.didit.me"
        expect(described_class.from_publishable_key(pk("pk_live_", ISSUER)).issuer).to eq(ISSUER)
        expect(described_class.from_publishable_key(pk("pk_test_", sandbox)).issuer).to eq(sandbox)
        expect(described_class.from_publishable_key("  #{pk("pk_live_", "#{ISSUER}/")}\n").issuer).to eq(ISSUER)
      end

      it "lets only a test key name a loopback http issuer" do
        %w[http://acme.auth.localhost:8000 http://localhost:8000 http://127.0.0.1:8000 http://[::1]:8000].each do |local|
          expect(described_class.from_publishable_key(pk("pk_test_", local)).issuer).to eq(local)
          expect { described_class.from_publishable_key(pk("pk_live_", local)) }.to raise_error(Didit::ConfigurationError)
        end
      end

      it "passes the options on" do
        auth = described_class.from_publishable_key(pk("pk_live_", ISSUER), client_id: APPLICATION_ID, leeway: 5,
                                                                             timeout: 3)
        expect([auth.issuer, auth.client_id, auth.leeway, auth.timeout]).to eq([ISSUER, APPLICATION_ID, 5.0, 3])
      end

      [
        "", "pk_live_", "pk_", "sk_live_#{AuthenticationHelper.b64url(ISSUER)}",
        "PK_LIVE_#{AuthenticationHelper.b64url(ISSUER)}", "pk_live_!!!notbase64",
        "pk_live_#{AuthenticationHelper.b64url(ISSUER)}=", "pk_live_#{[ISSUER].pack("m0")}=", "pk_live_a",
        "pk_live_#{AuthenticationHelper.b64url("\xff\xfe\xfd")}",
        "pk_live_#{AuthenticationHelper.b64url("http://acme.auth.didit.me")}",
        "pk_test_#{AuthenticationHelper.b64url("http://acme.auth.didit.me")}",
        "pk_live_#{AuthenticationHelper.b64url("acme.auth.didit.me")}",
        "pk_live_#{AuthenticationHelper.b64url("https://acme.auth.didit.me?x=1")}",
        "pk_live_#{AuthenticationHelper.b64url("https://acme.auth.didit.me")}x",
        nil, 42
      ].each do |publishable_key|
        it "refuses #{publishable_key.inspect}" do
          expect { described_class.from_publishable_key(publishable_key) }.to raise_error(Didit::ConfigurationError)
        end
      end
    end

    describe "issuer" do
      [
        "", "   ", "acme.auth.didit.me", "http://acme.auth.didit.me", "ftp://acme.auth.didit.me", "https://",
        "https://user:secret@acme.auth.didit.me", "https://acme.auth.didit.me/?x=1", "https://acme.auth.didit.me#top",
        "https://acme.auth.didit.me:99999", "https://acme.auth.didit.me:0", "https://acme.auth.didit.me/a b",
        "https://[::1", "http://localhost.example.com", "http://127.0.0.2", "pk_live_abc", nil, :issuer
      ].each do |value|
        it "refuses #{value.inspect}" do
          expect { described_class.new(value) }.to raise_error(Didit::ConfigurationError)
        end
      end

      it "drops trailing slashes and accepts loopback http" do
        expect(described_class.new("#{ISSUER}//").issuer).to eq(ISSUER)
        expect(described_class.new(" https://login.example.com/auth/ ").issuer).to eq("https://login.example.com/auth")
        expect(described_class.new("http://localhost:8000/").issuer).to eq("http://localhost:8000")
        expect(described_class.new("http://[::1]:8000").issuer).to eq("http://[::1]:8000")
      end

      it "says when it was given a publishable key" do
        expect { described_class.new("pk_live_abc") }.to raise_error(Didit::ConfigurationError, /from_publishable_key/)
      end
    end

    describe "options" do
      it "has documented defaults and a short inspect" do
        auth = described_class.new(ISSUER)
        expect([auth.client_id, auth.timeout, auth.leeway]).to eq([nil, 10, 60.0])
        expect(auth.inspect).to eq(%(#<Didit::Authentication issuer="#{ISSUER}" client_id=nil>))
        expect(described_class.new(ISSUER, client_id: " #{APPLICATION_ID} ").client_id).to eq(APPLICATION_ID)
      end

      it "refuses an empty client id, a bad leeway, timeout, http_client or clock" do
        expect { described_class.new(ISSUER, client_id: " ") }.to raise_error(Didit::ConfigurationError, /client_id/)
        expect { described_class.new(ISSUER, client_id: 7) }.to raise_error(Didit::ConfigurationError, /client_id/)
        [-1, true, "60", Float::NAN, Float::INFINITY].each do |leeway|
          expect { described_class.new(ISSUER, leeway: leeway) }.to raise_error(Didit::ConfigurationError, /leeway/)
        end
        [0, -1, "10", nil, Float::INFINITY].each do |timeout|
          expect { described_class.new(ISSUER, timeout: timeout) }.to raise_error(Didit::ConfigurationError, /timeout/)
        end
        expect { described_class.new(ISSUER, http_client: Object.new) }.to raise_error(Didit::ConfigurationError, /http_client/)
        expect { described_class.new(ISSUER, clock: 5) }.to raise_error(Didit::ConfigurationError, /clock/)
      end
    end

    describe "http_client" do
      let(:key) { AuthenticationHelper::SigningKey.generate("k_synthetic_key_1") }

      it "builds every connection, with the SDK's timeouts and no retries" do
        AuthenticationHelper::FakeIssuer.new([key])
        built = []
        factory = lambda do |uri|
          http = Net::HTTP.new(uri.hostname, uri.port)
          http.use_ssl = true
          built << [uri.to_s, http]
          http
        end
        auth = described_class.new(ISSUER, timeout: 4, http_client: factory, clock: AuthenticationHelper::FakeClock.new)
        auth.verify_access_token(key.sign(access_claims))

        expect(built.map(&:first)).to eq(["#{ISSUER}#{DISCOVERY}", "#{ISSUER}#{JWKS}"])
        http = built.last.last
        expect([http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries]).to eq([4, 4, 4, 0])
      end

      it "must return a Net::HTTP" do
        auth = described_class.new(ISSUER, http_client: ->(_uri) { :not_http })
        expect { auth.get_session(ACCESS_TOKEN) }.to raise_error(Didit::ConfigurationError, /Net::HTTP/)
      end
    end
  end
end
