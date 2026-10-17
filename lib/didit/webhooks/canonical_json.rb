# frozen_string_literal: true

module Didit
  module Webhooks
    # Canonical JSON, the text +X-Signature-V2+ signs (docs/DESIGN.md section 9.2).
    #
    # It is byte for byte what the Didit backend builds in Python:
    # +json.dumps(shorten_floats(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False)+.
    #
    # @api private
    module CanonicalJson
      # Deepest nesting of objects and arrays accepted, the default of Ruby's JSON parser.
      MAX_NESTING = 100

      # What Python's json.dumps escapes in a string; everything else is written as literal UTF-8.
      ESCAPES = (0x00..0x1f).to_h { |code| [code.chr(Encoding::UTF_8), format("\\u%04x", code)] }.merge(
        "\"" => "\\\"", "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\b" => "\\b", "\f" => "\\f"
      ).freeze
      ESCAPED = /["\\\x00-\x1f]/

      module_function

      # The canonical JSON text of a parsed JSON value (keys may be Strings or Symbols).
      #
      # @raise [ArgumentError] when the value is not JSON data (NaN, Infinity, a string that is
      #   not valid UTF-8 or holds a lone surrogate, nesting deeper than {MAX_NESTING}, another type)
      def generate(value)
        dump(normalize(value))
      end

      # A deep copy of a parsed JSON value with String keys and UTF-8 strings, checked to be
      # JSON data that Python's json.dumps can write.
      #
      # @raise [ArgumentError] see {generate}
      def normalize(value, depth = 0)
        case value
        when Hash then normalize_object(value, depth)
        when Array then normalize_array(value, depth)
        when String then utf8(value)
        when Float
          raise ArgumentError, "NaN and Infinity are not JSON numbers" unless value.finite?

          value
        when Integer, true, false, nil then value
        else raise ArgumentError, "a #{value.class} is not JSON data"
        end
      end

      # The canonical text of a value {normalize} returned.
      def dump(value)
        out = +""
        write(value, out)
        out
      end

      # Python's +str()+ of a parsed JSON scalar, as the backend formats the fields
      # +X-Signature-Simple+ signs; nil for an object or an array.
      def python_str(value)
        case value
        when nil then "None"
        when true then "True"
        when false then "False"
        when String then value
        when Integer then value.to_s
        when Float then float_repr(value)
        end
      end

      # Python's +repr()+ of a finite float: the shortest digits that round-trip (the digits
      # Ruby's Float#to_s picks too), in scientific notation when the decimal exponent is
      # below -4 or at least 16 (+1e-05+, +1.5e+16+), else in fixed notation (+0.0001+, +87.0+).
      def float_repr(value)
        return value.to_s if value.zero? # "0.0" or "-0.0", like Python

        text = value.to_s
        sign = text.start_with?("-") ? "-" : ""
        digits, point = decimal_digits(text.delete_prefix("-"))
        "#{sign}#{format_repr(digits, point)}"
      end

      # The significant digits of a positive Float#to_s and the position of the decimal point
      # relative to them: the value is 0.<digits> * 10**point.
      def decimal_digits(text)
        mantissa, exponent = text.split("e", 2)
        int, frac = mantissa.to_s.split(".", 2)
        int = int.to_s
        frac = frac.to_s
        point = int.length + (exponent ? Integer(exponent, 10) : 0)
        digits = "#{int}#{frac}"
        stripped = digits.sub(/\A0+/, "")
        point -= digits.length - stripped.length
        [stripped.sub(/0+\z/, ""), point]
      end

      def format_repr(digits, point)
        if point <= -4 || point > 16
          exponent = point - 1
          mantissa = digits.length > 1 ? "#{digits[0]}.#{digits[1..]}" : digits
          "#{mantissa}e#{exponent.negative? ? "-" : "+"}#{exponent.abs.to_s.rjust(2, "0")}"
        elsif point <= 0
          "0.#{"0" * -point}#{digits}"
        elsif point >= digits.length
          "#{digits}#{"0" * (point - digits.length)}.0"
        else
          "#{digits[0, point]}.#{digits[point..]}"
        end
      end

      def normalize_object(value, depth)
        raise ArgumentError, "JSON nesting is deeper than #{MAX_NESTING}" if depth >= MAX_NESTING

        # @type var out: Hash[String, untyped]
        out = {}
        value.each do |key, item|
          name = key_name(key)
          raise ArgumentError, "the object has the key #{name.inspect} twice" if out.key?(name)

          out[name] = normalize(item, depth + 1)
        end
        out
      end

      def normalize_array(value, depth)
        raise ArgumentError, "JSON nesting is deeper than #{MAX_NESTING}" if depth >= MAX_NESTING

        value.map { |item| normalize(item, depth + 1) }
      end

      def key_name(key)
        case key
        when String then utf8(key)
        when Symbol then utf8(key.name)
        else raise ArgumentError, "an object key must be a String or a Symbol, not a #{key.class}"
        end
      end

      def utf8(value)
        text =
          case value.encoding
          when Encoding::UTF_8 then value
          when Encoding::BINARY, Encoding::US_ASCII then value.dup.force_encoding(Encoding::UTF_8)
          else value.encode(Encoding::UTF_8)
          end
        raise ArgumentError, "a string is not valid UTF-8 or holds a lone surrogate" unless text.valid_encoding?

        text
      rescue EncodingError
        raise ArgumentError, "a string cannot be converted to UTF-8"
      end

      def write(value, out)
        case value
        when Hash then write_object(value, out)
        when Array then write_array(value, out)
        when String then write_string(value, out)
        when Float then out << (value.modulo(1).zero? ? value.to_i.to_s : float_repr(value))
        when nil then out << "null"
        else out << value.to_s # Integer, true, false
        end
      end

      def write_object(value, out)
        out << "{"
        value.keys.sort!.each_with_index do |key, index|
          out << "," if index.positive?
          write_string(key, out)
          out << ":"
          write(value[key], out)
        end
        out << "}"
      end

      def write_array(value, out)
        out << "["
        value.each_with_index do |item, index|
          out << "," if index.positive?
          write(item, out)
        end
        out << "]"
      end

      def write_string(value, out)
        out << "\"" << value.gsub(ESCAPED, ESCAPES) << "\""
      end
    end
  end
end
