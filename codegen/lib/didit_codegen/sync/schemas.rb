# frozen_string_literal: true

module DiditCodegen
  module Sync
    # Dereferenced schemas read the way docs/DESIGN.md section 3.1 compares them, step for step
    # like sdk-python's codegen/spec_sync.py, which generates openapi/breaking-vectors.json:
    # what a caller can observe (shape), whether a value can be null, the JSON types it allows,
    # its fields, and the variants of a union and how old and new ones pair up.
    module Schemas
      MAX_DEPTH = 32
      # String formats with their own type in the generated code: adding, removing or changing
      # one changes the field's type.
      TYPED_FORMATS = %w[date-time date binary].freeze
      UNIONS = %w[oneOf anyOf].freeze
      # The extension a caller can observe (the webhook events). Every other x- key documents;
      # x-didit-sdk is compared as the effective naming, together with overlay.json.
      OBSERVABLE_EXTENSIONS = %w[x-webhooks].freeze

      module_function

      # +value+, or +default+ when +value+ is empty (nil, false, 0, "", {} or []).
      def present(value, default)
        empty = value.nil? || value == false || (value.is_a?(Numeric) && value.zero?) ||
                ((value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)) && value.empty?)
        empty ? default : value
      end

      def list(value)
        value.is_a?(Array) ? value : []
      end

      # What a caller can observe in a document: no documentation, no info and no x-didit-sdk.
      def observable(data)
        shape(data.is_a?(Hash) ? data.except("info") : data)
      end

      # +node+ without documentation (DOC_KEYS, and x- keys but OBSERVABLE_EXTENSIONS), so that
      # only what is sent or received compares. The keys of a map of names (NAME_MAPS) all stay,
      # required and type lists compare in any order, and the title of a union variant stays as
      # the name it gives the variant's generated type.
      def shape(node, names: false, variant: false)
        case node
        when Hash
          node.each_with_object({}) do |(key, value), out|
            if variant && key == "title"
              name = variant_type_name(node)
              out[key] = name if name
            elsif names || !doc?(key)
              out[key] = shape_value(key, value, names)
            end
          end
        when Array then node.map { |value| shape(value) }
        else node
        end
      end

      def shape_value(key, value, names)
        return shape(value, names: !names && NAME_MAPS.include?(key)) if names || !value.is_a?(Array)

        case key
        when "required", "type" then value.sort_by(&:to_s)
        when *UNIONS then value.map { |member| shape(member, variant: true) }
        else shape(value, names: NAME_MAPS.include?(key))
        end
      end

      def doc?(key)
        DOC_KEYS.include?(key) || (key.start_with?("x-") && !OBSERVABLE_EXTENSIONS.include?(key))
      end

      # What an inline union variant's title adds to its generated type name; nil without one,
      # and for a $ref (named after its component).
      def variant_type_name(schema)
        return nil unless schema.is_a?(Hash) && !schema.key?("$ref")

        title = schema["title"]
        title.is_a?(String) && !title.strip.empty? ? Naming.pascal(title) : nil
      end

      def null_only?(schema)
        schema.is_a?(Hash) && (schema["type"] == "null" || schema["enum"] == [nil])
      end

      # The oneOf/anyOf variants other than null (of +keyword+, or of both).
      def variants(schema, keyword = nil)
        return [] unless schema.is_a?(Hash)

        (keyword ? [keyword] : UNIONS).flat_map { |k| list(schema[k]).reject { |v| null_only?(v) } }
      end

      def union_keyword(schema)
        UNIONS.find { |k| !variants(schema, k).empty? }
      end

      # Each of variants(schema) as the vectors number it: its keyword and its position from 1
      # in that keyword's list, a null variant included ("anyOf 2" in [null, X, Y]).
      def positions(schema)
        UNIONS.flat_map do |k|
          list(schema[k]).each_with_index.reject { |v, _| null_only?(v) }.map { |_, i| "#{k} #{i + 1}" }
        end
      end

      # A union's variant with the fields the union itself requires, which JSON Schema applies
      # to every variant: dropping one from the union drops it from each variant.
      def with_required(variant, union)
        inherited = list(union["required"]).grep(String)
        return variant if inherited.empty? || !variant.is_a?(Hash)

        variant.merge("required" => (list(variant["required"]).grep(String) | inherited).sort)
      end

      # Whether +schema+ accepts null: a null type, nullable, null in its enum, allOf members
      # that all do, or a null or nullable oneOf/anyOf variant.
      def nullable?(schema, depth = 0)
        return false unless schema.is_a?(Hash) && depth <= MAX_DEPTH

        raw = schema["type"]
        return true if raw == "null" || (raw.is_a?(Array) && raw.include?("null"))
        return true if schema["nullable"] == true
        return true if schema["enum"].is_a?(Array) && schema["enum"].include?(nil)

        members = list(schema["allOf"])
        return true if !schema.key?("type") && !members.empty? && members.all? { |m| nullable?(m, depth + 1) }

        UNIONS.any? { |k| list(schema[k]).any? { |v| nullable?(v, depth + 1) } }
      end

      # +schema+ read as one type: allOf members merged into it, and a oneOf/anyOf with a single
      # non-null variant replaced by that variant, so that anyOf [X, null] reads as a nullable X
      # rather than as X's fields removed.
      def single(schema, depth = 0)
        return schema unless schema.is_a?(Hash) && depth <= MAX_DEPTH

        members = schema["allOf"]
        schema = merge_all_of(schema, members, depth) if members.is_a?(Array) && members.all?(Hash)
        found = variants(schema)
        return schema unless found.size == 1 && found.first.is_a?(Hash)

        single(with_required(found.first, schema).merge(schema.except(*UNIONS, "required")), depth + 1)
      end

      def merge_all_of(schema, members, depth)
        merged = schema.except("allOf")
        members.each do |member|
          single(member, depth + 1).each do |key, value|
            if key == "properties" && value.is_a?(Hash)
              merged["properties"] = value.merge(present(merged["properties"], {}))
            elsif key == "required" && value.is_a?(Array)
              merged["required"] = (list(present(merged["required"], [])) | value).sort_by(&:to_s)
            elsif !merged.key?(key)
              merged[key] = value
            end
          end
        end
        merged
      end

      def json_type(value)
        case value
        when true, false then "boolean"
        when Integer then "integer"
        when Float then "number"
        when String then "string"
        when Array then "array"
        else "object"
        end
      end

      # The JSON types +schema+ allows besides null, sorted, inferred when it has no type (a
      # union allows its variants' types); empty when it does not say.
      def kinds(schema, depth = 0)
        return [] unless schema.is_a?(Hash) && depth <= MAX_DEPTH

        raw = schema["type"]
        found = (raw.is_a?(Array) ? raw : [raw]).grep(String) - ["null"]
        return found.uniq.sort unless found.empty?
        return ["object"] if %w[properties additionalProperties patternProperties].any? { |k| schema.key?(k) }
        return ["array"] if schema.key?("items")

        members = variants(schema)
        unless members.empty?
          each = members.map { |v| kinds(v, depth + 1) }
          return each.any?(&:empty?) ? [] : each.flatten.uniq.sort
        end
        list(schema["allOf"]).each { |member| found |= kinds(member, depth + 1) }
        found = values_of(schema).compact.map { |v| json_type(v) } if found.empty?
        found.uniq.sort
      end

      def values_of(schema)
        return [schema["const"]] if schema.key?("const")

        list(schema["enum"])
      end

      # +kinds+ as the summary names them (the vectors join them with "|"); a string with a
      # typed format is its own type, and a schema that does not say allows any value.
      def type_names(schema, kinds, separator = " or ")
        return "any" if kinds.empty?

        format = schema["format"]
        kinds.map { |k| k == "string" && TYPED_FORMATS.include?(format) ? "string (#{format})" : k }.join(separator)
      end

      # The types of a union's variants (or of a method's 2xx bodies) as the vectors name them:
      # sorted, and repeated per variant, so that losing one of two objects reads
      # "object|object -> object".
      def union_names(schemas)
        schemas.flat_map do |schema|
          one = schema.is_a?(Hash) ? single(schema) : {}
          type_names(one, kinds(one), "|").split("|")
        end.sort.join("|")
      end

      def enum_values(schema)
        values = schema["enum"]
        values.is_a?(Array) ? values.compact : nil
      end

      # [properties, required names] of an object schema, its allOf members included.
      def object_props(schema)
        props = {}
        required = []
        stack = [schema]
        until stack.empty?
          current = stack.pop
          next unless current.is_a?(Hash)

          props.merge!(current["properties"]) if current["properties"].is_a?(Hash)
          required |= list(current["required"]).grep(String)
          stack.concat(list(current["allOf"]))
        end
        [props, required]
      end

      def field_names(schema)
        schema.is_a?(Hash) ? object_props(single(schema)).first.keys : []
      end

      def compatible?(old, new)
        old_kinds = kinds(old)
        new_kinds = kinds(new)
        old_kinds.empty? || new_kinds.empty? || old_kinds == new_kinds
      end

      # Pairs each old union variant with the new one it became: an unchanged one first, then
      # one with the same title, then one of the same type with the most fields in common.
      # Returns the pairs [old position, new position] sorted by the new one, and the positions
      # left over on each side (variants removed and added).
      def pair_variants(old, new)
        left_old = (0...old.size).to_a
        left_new = (0...new.size).to_a
        pairs = []
        old_shapes = old.map { |v| shape(v) }
        new_shapes = new.map { |v| shape(v) }
        same_shape = ->(i, j) { old_shapes[i] == new_shapes[j] }
        same_title = ->(i, j) { !title_of(old[i]).nil? && title_of(old[i]) == title_of(new[j]) }
        [same_shape, same_title].each do |same|
          left_old.dup.each do |i|
            j = left_new.find { |candidate| same.call(i, candidate) }
            pairs << [left_old.delete(i), left_new.delete(j)] if j
          end
        end
        closest(old, new, left_old, left_new).each do |_, i, j|
          pairs << [left_old.delete(i), left_new.delete(j)] if left_old.include?(i) && left_new.include?(j)
        end
        [pairs.sort_by(&:last), left_old, left_new]
      end

      # [-fields in common, old position, new position] of every compatible pair left, best first.
      def closest(old, new, left_old, left_new)
        left_old.product(left_new).filter_map do |i, j|
          [-(field_names(old[i]) & field_names(new[j])).size, i, j] if compatible?(old[i], new[j])
        end.sort
      end

      def title_of(schema)
        schema.is_a?(Hash) ? schema["title"] : nil
      end
    end
  end
end
