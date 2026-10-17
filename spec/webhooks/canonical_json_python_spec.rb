# frozen_string_literal: true

require "json"
require "open3"

# Compares canonical_json with the backend's own serialisation, run by a real Python, on random
# payloads. Skipped when python3 is not on PATH. No network: Python runs locally on stdin.
RSpec.describe "Didit::Webhooks.canonical_json against Python" do
  # shorten_floats is copied verbatim from service-didit-verification src/sessions/utils/webhooks.py.
  script = <<~'PYTHON'
    import json
    import sys


    def shorten_floats(data):
        """
        Recursively process float values in the data structure
        """
        if isinstance(data, dict):
            return {key: shorten_floats(value) for key, value in data.items()}
        elif isinstance(data, list):
            return [shorten_floats(item) for item in data]
        elif isinstance(data, float):
            if data.is_integer():
                return int(data)
            return data
        return data


    for line in sys.stdin.buffer.read().split(b"\n"):
        if line:
            value = json.loads(line.decode("utf-8"))
            text = json.dumps(shorten_floats(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            sys.stdout.buffer.write(text.encode("utf-8") + b"\n")
  PYTHON

  python = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "python3") }
              .find { |path| File.file?(path) && File.executable?(path) }

  # Characters that stress escaping and key order: controls, quotes, DEL, line separators,
  # the private use area, U+FFFF, astral characters and plain text.
  chars = [*"\u0000".."\u001f", "\"", "\\", "/", "\u007f", "\u0080", "é", "ß", "\u2028", "\u2029", "\u{e000}",
           "\u{fb00}", "\u{fffd}", "\u{ffff}", "😀", "\u{10000}", "\u{10ffff}", "山", "a", "b", "Z", " ", "0"]

  let(:rng) { Random.new(RSpec.configuration.seed) }

  def random_string(chars)
    Array.new(rng.rand(0..8)) { chars.sample(random: rng) }.join
  end

  def random_float
    case rng.rand(8)
    when 0 then loop { (f = [rng.rand(2**64)].pack("Q").unpack1("D")).finite? && (break f) }
    when 1 then [rng.rand(2**52)].pack("Q").unpack1("D") * [1, -1].sample(random: rng) # subnormal
    when 2 then [0.0, -0.0, 1.0, -1.0, 87.0, 1e16, 1e300, 1e-5, 1e-7, 0.1].sample(random: rng)
    when 3 then rng.rand(10**15..10**17) + (rng.rand(1..9) / 10.0) # 1e15..1e17 with a fraction
    when 4 then rng.rand * (10.0**rng.rand(-30..30))
    when 5 then rng.rand(1..99_999) / (10.0**rng.rand(1..12))
    when 6 then rng.rand(-10_000..10_000) / 8.0
    else 10.0**rng.rand(-320..308)
    end
  end

  def random_scalar(chars)
    case rng.rand(7)
    when 0 then random_float
    when 1 then rng.rand(-(10**30)..10**30)
    when 2 then rng.rand(-1000..1000)
    when 3 then [true, false, nil].sample(random: rng)
    else random_string(chars)
    end
  end

  def random_value(chars, depth = 0)
    case depth < 4 ? rng.rand(4) : 3
    when 0 then Array.new(rng.rand(0..5)) { random_value(chars, depth + 1) }
    when 1 then Array.new(rng.rand(0..5)) { [random_string(chars), random_value(chars, depth + 1)] }.to_h
    else random_scalar(chars)
    end
  end

  # Number literals the way other encoders write them, to compare the two parsers too.
  def random_number_literal
    digits = Array.new(rng.rand(1..25)) { rng.rand(10) }.join.sub(/\A0+(?=\d)/, "")
    fraction = rng.rand(2).zero? ? "" : ".#{Array.new(rng.rand(1..20)) { rng.rand(10) }.join}"
    # At most 25 digits and e+280: never beyond Float::MAX, which Python and Ruby read as Infinity.
    exponent = rng.rand(2).zero? ? "" : "#{%w[e E e+ e-].sample(random: rng)}#{rng.rand(0..280)}"
    "#{"-" if rng.rand(2).zero?}#{digits}#{fraction}#{exponent}"
  end

  it "is byte for byte what Python's json.dumps writes, on 3000 random payloads" do
    skip "python3 is not on PATH" unless python

    edge_literals = %w[0 -0 0.0 -0.0 1E5 1e-7 2.5E+3 1.0 1e16 1e-400 2.4703282292062327e-324
                       2.4703282292062328e-324 1.7976931348623157e308 0.1000000000000000055511151231257827
                       9007199254740993 9007199254740993.0 123456789012345678901234567890]
    lines = Array.new(2500) { JSON.generate({ "v" => random_value(chars), random_string(chars) => random_value(chars) }) }
    lines += Array.new(500) { "{\"n\":[#{Array.new(8) { random_number_literal }.join(",")}]}" }
    lines << "{\"n\":[#{edge_literals.join(",")}]}"

    output, status = Open3.capture2(python, "-c", script, stdin_data: lines.join("\n"), binmode: true)
    expect(status).to be_success
    expected = output.force_encoding(Encoding::UTF_8).split("\n", -1)[0...-1]
    expect(expected.size).to eq(lines.size)

    mismatches = lines.zip(expected).reject do |line, python_text|
      Didit::Webhooks.canonical_json(JSON.parse(line)).b == python_text.b
    end
    expect(mismatches.first(3)).to be_empty, "seed #{RSpec.configuration.seed}: #{mismatches.size} mismatches"
  end
end
