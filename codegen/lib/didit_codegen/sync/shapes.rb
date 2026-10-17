# frozen_string_literal: true

module DiditCodegen
  module Sync
    # The shape of a schema as the SDK sees it: its coarse type, whether it can be null,
    # and its properties with allOf parts and object variants merged.
    module Shapes
      MAX_DEPTH = 24
      DATED_FORMATS = %w[date date-time binary].freeze

      module_function

      def hash(value)
        value.is_a?(Hash) ? value : {}
      end

      def null_schema?(doc, schema)
        schema = doc.expand(schema)
        schema.is_a?(Hash) && ["null", ["null"]].include?(schema["type"])
      end

      def nullable?(doc, schema)
        return false unless schema.is_a?(Hash)
        return true if schema["nullable"] == true
        return true if schema["type"].is_a?(Array) && schema["type"].include?("null")

        %w[oneOf anyOf].any? { |k| Array(schema[k]).any? { |v| null_schema?(doc, v) } }
      end

      # A coarse type name ("string", "string(date-time)", "object", "map", "a|b"); an
      # empty string means any type.
      def kind(doc, schema)
        return "" unless schema.is_a?(Hash)

        variants = schema["oneOf"] || schema["anyOf"]
        variants = variants.is_a?(Array) ? variants.reject { |v| null_schema?(doc, v) } : []
        unless variants.empty?
          kinds = variants.map { |v| kind(doc, flatten(doc, v)) }.map { |k| k.empty? ? "any" : k }
          return kinds.uniq.sort.join("|")
        end

        type = schema["type"]
        type = type.find { |t| t != "null" } if type.is_a?(Array)
        case type
        when "string" then DATED_FORMATS.include?(schema["format"]) ? "string(#{schema["format"]})" : "string"
        when "integer", "number", "boolean", "array" then type
        else object_kind(schema, type)
        end
      end

      def object_kind(schema, type)
        return "" unless type == "object" || schema["properties"].is_a?(Hash)

        extra = schema["additionalProperties"]
        hash(schema["properties"]).empty? && extra.is_a?(Hash) && !extra.empty? ? "map" : "object"
      end

      def objectish?(schema)
        schema.is_a?(Hash) && (schema["type"] == "object" || !hash(schema["properties"]).empty?)
      end

      # +schema+ resolved, with allOf parts merged, and object oneOf/anyOf variants merged
      # into one object (the properties of all, the required fields of every variant).
      def flatten(doc, schema, depth = 0)
        schema = doc.expand(schema)
        return schema if !schema.is_a?(Hash) || depth > MAX_DEPTH

        parts = schema["allOf"]
        return merge_all_of(doc, schema, parts, depth) if parts.is_a?(Array) && !parts.empty?

        keyword = %w[oneOf anyOf].find { |k| schema[k].is_a?(Array) && !schema[k].empty? }
        keyword ? merge_variants(doc, schema, keyword, depth) : schema
      end

      def merge_all_of(doc, schema, parts, depth)
        flat = parts.map { |p| flatten(doc, p, depth + 1) }
        rest = schema.except("allOf")
        return flat.first.merge(rest) if flat.size == 1 && flat.first.is_a?(Hash) && !objectish?(flat.first)

        out = merged_object(rest, flat + [rest], :union)
        out["nullable"] = true if flat.any? { |p| p.is_a?(Hash) && p["nullable"] == true }
        out
      end

      def merge_variants(doc, schema, keyword, depth)
        flat = schema[keyword].reject { |v| null_schema?(doc, v) }.map { |v| flatten(doc, v, depth + 1) }
        rest = schema.except("oneOf", "anyOf")
        nullable = schema[keyword].size != flat.size
        out = if flat.size == 1 && flat.first.is_a?(Hash)
                flat.first.merge(rest)
              elsif !flat.empty? && flat.all? { |v| objectish?(v) }
                merged_object(rest, flat, :intersection)
              end
        return schema if out.nil?

        out["nullable"] = true if nullable
        out
      end

      # One object schema from +parts+. :union (allOf): every property, a later part wins,
      # and the required fields of all parts. :intersection (oneOf/anyOf): every property,
      # the first variant wins, and the fields every variant requires.
      def merged_object(rest, parts, mode)
        parts = parts.grep(Hash)
        props = {}
        parts.each do |part|
          hash(part["properties"]).each { |name, prop| props[name] = prop if mode == :union || !props.key?(name) }
        end
        lists = parts.map { |p| Array(p["required"]) }
        names = mode == :union ? lists.flatten.uniq : (lists.reduce(:&) || [])
        rest.merge("type" => "object", "properties" => props, "required" => names)
      end
    end
  end
end
