# frozen_string_literal: true

require "json"

module DiditCodegen
  # Values for the generated tests: the spec's examples when they fit the schema,
  # otherwise values synthesised from the schema.
  module Samples
    UUID = "3f1c2a9e-5b7d-4e2f-9a1b-6c8d0e4f2a7b"
    # Example values under these keys, and anything shaped like a JWT, are replaced in tests,
    # so committed tests never carry token-shaped strings (the repository's gitleaks scan).
    SECRET_KEYS = /token|secret|password|api_?key|authorization|private_key|credential/i
    TOKEN_SHAPED = /\AeyJ[A-Za-z0-9_-]{4,}/
    MAX_DEPTH = 4

    module_function

    # A value for +schema+; +all+ also fills optional properties.
    def synthesize(document, schema, depth: 0, all: false, name: nil)
      schema = document.resolve(schema)
      return nil unless schema.is_a?(Hash)
      return "example" if depth > MAX_DEPTH

      if schema.key?("allOf")
        merged = schema["allOf"].each_with_object({ "type" => "object", "properties" => {},
                                                    "required" => [] }) do |p, m|
          p = document.resolve(p)
          m["properties"].merge!(p["properties"] || {})
          m["required"] |= Array(p["required"])
        end
        merged["properties"].merge!(schema["properties"] || {})
        merged["required"] |= Array(schema["required"])
        return synthesize(document, merged, depth: depth, all: all, name: name)
      end
      %w[oneOf anyOf].each do |key|
        next unless schema.key?(key)

        member = schema[key].find { |m| document.resolve(m)["type"] != "null" } || {}
        return synthesize(document, member, depth: depth, all: all, name: name)
      end
      return schema["enum"].compact.first if schema.key?("enum")

      basic(document, schema, depth, all, name)
    end

    def basic(document, schema, depth, all, name)
      case schema["type"]
      when "string" then string_value(schema, name)
      when "integer" then 1
      when "number" then 1.5
      when "boolean" then true
      when "array" then [synthesize(document, schema["items"] || {}, depth: depth + 1, all: all, name: name)]
      else
        props = schema["properties"] || {}
        if props.empty?
          extra = schema["additionalProperties"]
          return {} unless extra.is_a?(Hash) && !extra.empty?

          return { "key" => synthesize(document, extra, depth: depth + 1, all: all) }
        end
        required = Array(schema["required"])
        props.each_with_object({}) do |(key, prop), out|
          next unless all || required.include?(key)
          next if document.resolve(prop)["readOnly"] == true && !all

          out[key] = synthesize(document, prop, depth: depth + 1, all: all, name: key)
        end
      end
    end

    def string_value(schema, name)
      example = schema["example"]
      return safe_string(example) if example.is_a?(String) && !secret?(name) && !example.match?(TOKEN_SHAPED)

      case schema["format"]
      when "date-time" then "2026-01-02T03:04:05Z"
      when "date" then "2026-01-02"
      when "uuid" then UUID
      when "email" then "user@example.com"
      when "uri", "url" then "https://example.com/callback"
      else name ? "#{name}-value" : "value"
      end
    end

    def safe_string(value)
      value.length > 200 ? value[0, 200] : value
    end

    def secret?(name)
      !name.nil? && name.match?(SECRET_KEYS)
    end

    # Replaces credential-like values in an example (so tests never carry token-shaped strings).
    def scrub(value, key = nil)
      case value
      when Hash then value.to_h { |k, v| [k, scrub(v, k)] }
      when Array then value.map { |v| scrub(v, key) }
      when String then secret?(key) || value.match?(TOKEN_SHAPED) ? "redacted-#{key || 'value'}" : value
      else value
      end
    end

    # Whether +example+ fits an object schema well enough to send as is.
    def fits?(document, schema, example)
      schema = document.resolve(schema)
      return false unless example.is_a?(Hash) && schema.is_a?(Hash)

      props = {}
      required = Array(schema["required"])
      ([schema] + (schema["allOf"] || []).map { |p| document.resolve(p) }).each do |part|
        props.merge!(part["properties"] || {})
        required |= Array(part["required"])
      end
      (example.keys - props.keys).empty? && (required - example.keys).empty?
    end

    # Ruby source for a JSON value; +symbols+ writes identifier keys as symbols.
    def literal(value, indent, symbols: false)
      case value
      when Hash then hash_literal(value, indent, symbols)
      when Array
        return "[]" if value.empty?

        items = value.map { |v| "#{indent}  #{literal(v, "#{indent}  ", symbols: symbols)}" }
        "[\n#{items.join(",\n")}\n#{indent}]"
      when String, Float then value.inspect
      when nil then "nil"
      else value.to_s
      end
    end

    def hash_literal(value, indent, symbols)
      return "{}" if value.empty?

      simple = symbols && value.keys.all? { |k| k.match?(/\A[a-z_][a-z0-9_]*\z/) }
      items = value.map do |k, v|
        key = simple ? "#{k}:" : "#{k.inspect} =>"
        "#{indent}  #{key} #{literal(v, "#{indent}  ", symbols: symbols)}"
      end
      "{\n#{items.join(",\n")}\n#{indent}}"
    end
  end
end
