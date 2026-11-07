# frozen_string_literal: true

require_relative "webhooks_helper"

module WebhookSpecs
  RSpec.describe "Didit::Webhooks.canonical_json" do
    def canonical(value)
      Didit::Webhooks.canonical_json(value)
    end

    {
      "sorts keys and drops whitespace" => [
        { "b" => 1, "a" => [2, { "d" => nil, "c" => true }] }, '{"a":[2,{"c":true,"d":null}],"b":1}'
      ],
      "writes integral floats as integers" => [
        { "score" => 87.0, "neg" => -3.0, "zero" => -0.0 }, '{"neg":-3,"score":87,"zero":0}'
      ],
      "writes 1e16 in full" => [{ "x" => 1e16 }, '{"x":10000000000000000}'],
      "writes 1e300 exactly" => [[1e300], "[#{1e300.to_i}]"],
      "keeps big integers exact" => [
        [9_007_199_254_740_993, -(10**30)], "[9007199254740993,-1000000000000000000000000000000]"
      ],
      "writes small floats like Python" => [
        [1e-05, 1.5e-07, 1.2345e-05, 0.0001, 0.1, -2.5], "[1e-05,1.5e-07,1.2345e-05,0.0001,0.1,-2.5]"
      ],
      "writes large non-integral floats" => [
        [1_234_567_890_123_456.7, 123_456_789.123], "[1234567890123456.8,123456789.123]"
      ],
      "writes subnormals" => [[5e-324, 2.2250738585072014e-308], "[5e-324,2.2250738585072014e-308]"],
      "writes true, false and null" => [[true, false, nil], "[true,false,null]"],
      "escapes only what Python escapes" => [
        { "s" => "q\"\\\n\r\t\b\f\u0000\u0007\u001f/\u007f\u2028\u2029" },
        ['{"s":"q\\"\\\\\\n\\r\\t\\b\\f\\u0000\\u0007\\u001f/', "\u007f\u2028\u2029", '"}'].join
      ],
      "keeps non-ASCII as UTF-8" => [{ "s" => "José 山田 😀" }, "{\"s\":\"José 山田 😀\"}"],
      "sorts keys by code point, not UTF-16 unit" => [
        { "😀" => 1, "\u{e000}" => 2, "\u{ffff}" => 3, "é" => 4, "z" => 5 },
        "{\"z\":5,\"é\":4,\"\u{e000}\":2,\"\u{ffff}\":3,\"😀\":1}"
      ],
      "accepts symbol keys" => [{ b: 1, a: { c: 2 } }, '{"a":{"c":2},"b":1}'],
      "writes empty containers" => [{ "a" => {}, "b" => [] }, '{"a":{},"b":[]}'],
      "writes scalars at the top" => ["x", '"x"']
    }.each do |description, (value, expected)|
      it description do
        expect(canonical(value)).to eq(expected)
      end
    end

    it "returns UTF-8" do
      expect(canonical({ "a" => "é" }).encoding).to eq(Encoding::UTF_8)
    end

    it "reads strings in other encodings as their characters" do
      expect(canonical(["José".encode("UTF-16LE"), "abc".b, "abc".encode("US-ASCII")])).to eq('["José","abc","abc"]')
    end

    it "keeps the last value of a repeated key after parsing, like Python" do
      expect(canonical(JSON.parse('{"a":1,"a":2}', allow_duplicate_key: true))).to eq('{"a":2}')
    end

    describe "values Python cannot serialise" do
      [
        ["NaN", [Float::NAN]],
        ["Infinity", { "x" => Float::INFINITY }],
        ["-Infinity", [-Float::INFINITY]],
        ["a lone surrogate", [(+"a\xED\xA0\x80b").force_encoding(Encoding::UTF_8)]],
        ["invalid UTF-8", ["\xFF".b]],
        ["a lone surrogate in UTF-16", [(+"\xD8\x00").force_encoding(Encoding::UTF_16BE)]],
        ["a Symbol value", [:approved]],
        ["a Time", [Time.at(0)]],
        ["a Rational", [Rational(1, 3)]],
        ["an Integer key", { 1 => 2 }],
        ["the same key as String and Symbol", { "a" => 1, a: 2 }]
      ].each do |description, value|
        it "raises ArgumentError for #{description}" do
          expect { canonical(value) }.to raise_error(ArgumentError)
        end
      end

      it "raises ArgumentError past #{Didit::Webhooks::CanonicalJson::MAX_NESTING} levels of nesting" do
        ok = (1...Didit::Webhooks::CanonicalJson::MAX_NESTING).reduce([]) { |inner, _| [inner] }
        expect(canonical(ok)).to eq(("[" * 100) + ("]" * 100))
        expect { canonical([ok]) }.to raise_error(ArgumentError, /nesting/)
        looped = []
        looped << looped
        expect { canonical(looped) }.to raise_error(ArgumentError, /nesting/)
      end
    end

    describe Didit::Webhooks::CanonicalJson do
      # repr() of CPython 3.12, which the backend's str() and json.dumps use for floats.
      [
        [0.0, "0.0"], [-0.0, "-0.0"], [87.0, "87.0"], [100.0, "100.0"], [0.1, "0.1"], [0.5, "0.5"],
        [1e-05, "1e-05"], [-1e-05, "-1e-05"], [0.0001, "0.0001"], [9.999999999999999e-05, "9.999999999999999e-05"],
        [1.5e-07, "1.5e-07"], [-2.5e-07, "-2.5e-07"], [1e15, "1000000000000000.0"], [1e16, "1e+16"],
        [9_999_999_999_999_998.0, "9999999999999998.0"], [12_345_678_901_234_567.0, "1.2345678901234568e+16"],
        [1e22, "1e+22"], [1.2345e20, "1.2345e+20"], [1.5e300, "1.5e+300"], [Float::MAX, "1.7976931348623157e+308"],
        [5e-324, "5e-324"], [0.30000000000000004, "0.30000000000000004"], [1.0 / 3, "0.3333333333333333"],
        [1.0000000000000002, "1.0000000000000002"], [4.35, "4.35"], [299_792_458.0, "299792458.0"],
        [123_456_789.12345679, "123456789.12345679"]
      ].each do |value, repr|
        it "writes #{repr} like Python repr" do
          expect(described_class.float_repr(value)).to eq(repr)
        end
      end

      it "formats X-Signature-Simple fields like Python str()" do
        values = [nil, true, false, "Approved", 1_760_702_400, -7, 2.5, 1.0, 1e-05, { "a" => 1 }, [1]]
        expect(values.map { |v| described_class.python_str(v) })
          .to eq(["None", "True", "False", "Approved", "1760702400", "-7", "2.5", "1.0", "1e-05", nil, nil])
      end
    end
  end
end
