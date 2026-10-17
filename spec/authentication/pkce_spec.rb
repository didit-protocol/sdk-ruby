# frozen_string_literal: true

require "digest"
require_relative "authentication_helper"

RSpec.describe Didit::Authentication::Pkce do
  let(:verifier_alphabet) { /\A[A-Za-z0-9\-._~]+\z/ }
  let(:url_safe) { /\A[A-Za-z0-9_-]+\z/ }

  it "computes the S256 challenge of RFC 7636 appendix B" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    expect(described_class.s256_challenge(verifier)).to eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    pair = described_class.new(verifier)
    expect([pair.code_verifier, pair.code_challenge, pair.code_challenge_method])
      .to eq([verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256"])
  end

  it "creates random verifiers of 43 to 128 characters with their challenge" do
    pairs = Array.new(20) { Didit::Authentication.create_pkce }
    pairs.each do |pair|
      expect(pair).to be_a(described_class)
      expect(pair.code_verifier.length).to be_between(43, 128)
      expect(pair.code_verifier).to match(verifier_alphabet)
      expect(pair.code_challenge).to eq(described_class.s256_challenge(pair.code_verifier))
      expect(pair.code_challenge.length).to eq(43)
      expect(pair.code_challenge_method).to eq("S256")
      expect(pair.inspect).not_to include(pair.code_verifier)
      expect(pair.to_s).not_to include(pair.code_verifier)
    end
    expect(pairs.map(&:code_verifier).uniq.length).to eq(20)
  end

  it "is frozen and converts to a Hash" do
    pair = Didit::Authentication.create_pkce
    expect(pair).to be_frozen
    expect(pair.to_h.keys).to eq(%i[code_verifier code_challenge code_challenge_method])
  end

  it "refuses a verifier RFC 7636 does not allow" do
    ["a" * 42, "a" * 129, "#{"a" * 42}!", "#{"a" * 42} ", nil, 42].each do |bad|
      expect { described_class.new(bad) }.to raise_error(Didit::ConfigurationError, /code_verifier/)
    end
    expect(described_class.new("a" * 128).code_verifier.length).to eq(128)
  end

  it "creates random url-safe state and nonce values of at least 128 bits" do
    values = Array.new(10) { Didit::Authentication.create_state } + Array.new(10) { Didit::Authentication.create_nonce }
    expect(values.uniq.length).to eq(20)
    values.each do |value|
      expect(value.length).to be >= 43
      expect(value).to match(url_safe)
    end
  end
end
