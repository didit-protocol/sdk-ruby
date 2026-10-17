# frozen_string_literal: true

module DiditCodegen
  module Sync
    # Keys that only document a schema or an operation.
    DOC_KEYS = %w[description summary title example examples externalDocs].freeze
    # Keys whose value maps names (property names, media types, status codes) to objects.
    # Inside them every key is a name, never a keyword: a property called "title" is a field.
    NAME_MAPS = %w[properties patternProperties content responses headers schemas encoding links callbacks].freeze

    # Deep equality of two spec fragments, the old one read in +old+ and the new one in +new+,
    # following $refs on each side. With +ignore_docs+ documentation keys do not count.
    class Comparer
      def initialize(old, new, ignore_docs:)
        @old = old
        @new = new
        @ignore_docs = ignore_docs
        @memo = {}
        @active = {}
      end

      # +names+ tells that the keys of +a+ and +b+ are names (see NAME_MAPS).
      def equal?(a, b, names: false)
        if a.is_a?(Hash) && b.is_a?(Hash)
          return refs_equal?(a, b) if !names && (a.key?("$ref") || b.key?("$ref"))

          keys = a.keys | b.keys
          keys = keys.reject { |k| doc_key?(k) } if @ignore_docs && !names
          keys.all? do |k|
            a.key?(k) && b.key?(k) && equal?(a[k], b[k], names: !names && NAME_MAPS.include?(k))
          end
        elsif a.is_a?(Array) && b.is_a?(Array)
          a.size == b.size && a.each_index.all? { |i| equal?(a[i], b[i]) }
        else
          a.instance_of?(b.class) && a == b
        end
      end

      private

      def doc_key?(key)
        DOC_KEYS.include?(key) || key.start_with?("x-")
      end

      def refs_equal?(a, b)
        key = [a["$ref"], b["$ref"]]
        pure = (a.keys - ["$ref"]).empty? && (b.keys - ["$ref"]).empty?
        return @memo[key] if pure && @memo.key?(key)
        # A recursive schema: equal unless something else differs.
        return true if @active.key?(key)

        @active[key] = true
        result = equal?(@old.expand(a), @new.expand(b))
        @active.delete(key)
        @memo[key] = result if pure
        result
      end
    end

    # The field-level differences between two versions of an operation: parameters,
    # request body and success responses, nested objects and $refs included. Each note
    # is [text, breaking]. A change breaks callers when code written against the SDK can
    # stop working: a removed or newly required request field, a removed response field,
    # a type change, an enum value removed from a request (response enums are open,
    # docs/DESIGN.md section 5.1).
    class Details
      MAX_DEPTH = 24

      attr_reader :notes

      def initialize(old, new)
        @old = old
        @new = new
        @notes = []
        @seen = {}
      end

      # @return [Array<Array(String, Boolean)>]
      def operation(old_ref, new_ref)
        parameters(old_ref.parameters, new_ref.parameters)
        request_body(old_ref.op["requestBody"], new_ref.op["requestBody"])
        responses(old_ref.op["responses"], new_ref.op["responses"])
        if old_ref.op["deprecated"] != true && new_ref.op["deprecated"] == true
          note("marked deprecated upstream", false)
        end
        @notes.uniq
      end

      def parameters(old_params, new_params)
        old_params.each do |key, param|
          label = "#{param["in"]} parameter `#{param["name"]}`"
          other = new_params[key]
          if other.nil?
            note("#{label}: removed", true)
            next
          end
          note("#{label}: now required", true) if other["required"] == true && param["required"] != true
          schema(param["schema"] || {}, other["schema"] || {}, label, "", :request)
        end
        new_params.each do |key, param|
          next if old_params.key?(key)

          label = "#{param["in"]} parameter `#{param["name"]}`"
          param["required"] == true ? note("#{label}: new required parameter", true) : note("#{label}: added", false)
        end
      end

      def request_body(old_body, new_body)
        old_body = @old.expand(old_body)
        new_body = @new.expand(new_body)
        return if old_body.nil? && new_body.nil?
        return note("request body: removed", true) unless new_body.is_a?(Hash)
        return added_body(new_body) unless old_body.is_a?(Hash)

        old_content = hash(old_body["content"])
        new_content = hash(new_body["content"])
        (old_content.keys - new_content.keys).each { |t| note("request body: content type `#{t}` removed", true) }
        (new_content.keys - old_content.keys).each { |t| note("request body: content type `#{t}` added", false) }
        note("request body: now required", true) if old_body["required"] != true && new_body["required"] == true
        media_pairs(old_content, new_content).each do |a, b|
          schema(hash(old_content[a])["schema"] || {}, hash(new_content[b])["schema"] || {}, "request body", "",
                 :request)
        end
      end

      def responses(old_responses, new_responses)
        old_ok = success(@old, old_responses)
        new_ok = success(@new, new_responses)
        pairs = old_ok.keys.select { |s| new_ok.key?(s) }.map { |s| [s, s] }
        if pairs.empty? && old_ok.size == 1 && new_ok.size == 1
          pairs = [[old_ok.keys.first, new_ok.keys.first]]
          note("success status changed from #{pairs[0][0]} to #{pairs[0][1]}", false)
        else
          (old_ok.keys - new_ok.keys).each { |s| note("response #{s}: removed", false) }
          (new_ok.keys - old_ok.keys).each { |s| note("response #{s}: added", false) }
        end
        pairs.each { |a, b| response(old_ok[a], new_ok[b], b) }
      end

      # Compares two schemas; +mode+ is :request or :response.
      def schema(old_schema, new_schema, label, path, mode, depth = 0)
        return if depth > MAX_DEPTH
        return unless first_visit?(old_schema, new_schema, mode)

        a = flatten(@old, old_schema)
        b = flatten(@new, new_schema)
        where = at(label, path)
        return if type_changed?(a, b, where, mode)
        return unless a.is_a?(Hash) && b.is_a?(Hash)

        nullability(a, b, where, mode)
        enum(a, b, where, mode)
        properties(a, b, label, path, mode, depth) if a["properties"] || b["properties"]
        variants(a, b, where)
        schema(a["items"] || {}, b["items"] || {}, label, "#{path}[]", mode, depth + 1) if kind(@old, a) == "array"
        extra_a = a["additionalProperties"]
        extra_b = b["additionalProperties"]
        return unless extra_a.is_a?(Hash) && extra_b.is_a?(Hash)

        schema(extra_a, extra_b, label, "#{path}{}", mode, depth + 1)
      end

      private

      def note(text, breaking)
        @notes << [text, breaking]
        nil
      end

      def hash(value)
        value.is_a?(Hash) ? value : {}
      end

      def at(label, path)
        path.empty? ? label : "#{label} `#{path}`"
      end

      def first_visit?(old_schema, new_schema, mode)
        refs = [old_schema, new_schema].map { |s| s.is_a?(Hash) ? s["$ref"] : nil }
        return true if refs.none?

        key = refs + [mode]
        return false if @seen.key?(key)

        @seen[key] = true
      end

      def added_body(body)
        required = hash(body["content"]).values.flat_map do |media|
          Array(hash(flatten(@new, hash(media)["schema"] || {}))["required"])
        end.uniq.sort
        if body["required"] == true && !required.empty?
          note("request body: added with required fields #{required.map { |r| "`#{r}`" }.join(", ")}", true)
        else
          note("request body: added", false)
        end
      end

      def media_pairs(old_content, new_content)
        common = old_content.keys & new_content.keys
        return common.map { |t| [t, t] } unless common.empty?
        return [] if old_content.empty? || new_content.empty?

        [[main_type(old_content), main_type(new_content)]]
      end

      def main_type(content)
        content.key?("application/json") ? "application/json" : content.keys.first
      end

      def success(doc, responses)
        hash(responses).each_with_object({}) do |(status, response), out|
          out[status.to_s] = hash(doc.expand(response)) if status.to_s.start_with?("2")
        end
      end

      def response(old_response, new_response, status)
        old_content = hash(old_response["content"])
        new_content = hash(new_response["content"])
        old_type = old_content.empty? ? nil : main_type(old_content)
        new_type = new_content.empty? ? nil : main_type(new_content)
        if old_type != new_type
          note("response #{status}: content type changed from #{old_type || "none"} to #{new_type || "none"}", true)
        elsif old_type
          schema(hash(old_content[old_type])["schema"] || {}, hash(new_content[new_type])["schema"] || {},
                 "response #{status}", "", :response)
        end
      end

      def type_changed?(a, b, where, mode)
        old_kind = kind(@old, a)
        new_kind = kind(@new, b)
        return false if old_kind.empty? || new_kind.empty? || old_kind == new_kind

        note("#{where}: type changed from #{old_kind} to #{new_kind}", !harmless?(old_kind, new_kind, mode))
        true
      end

      # Widening what a request accepts, or narrowing what a response returns, breaks nobody.
      def harmless?(old_kind, new_kind, mode)
        if mode == :request
          (old_kind == "integer" && new_kind == "number") ||
            (old_kind == "string" && %w[string(date) string(date-time)].include?(new_kind))
        else
          old_kind == "number" && new_kind == "integer"
        end
      end

      def nullability(a, b, where, mode)
        old_null = nullable?(@old, a)
        new_null = nullable?(@new, b)
        note("#{where}: can now be null", true) if mode == :response && new_null && !old_null
        note("#{where}: no longer accepts null", true) if mode == :request && old_null && !new_null
      end

      def enum(a, b, where, mode)
        old_values = a["enum"]
        new_values = b["enum"]
        if old_values.is_a?(Array) && new_values.is_a?(Array)
          (old_values - new_values).compact.each do |value|
            note("#{where}: enum value `#{value}` removed", mode == :request)
          end
          added = (new_values - old_values).compact
          note("#{where}: enum #{values(added)} added", false) unless added.empty?
        elsif new_values.is_a?(Array)
          note("#{where}: now limited to #{values(new_values.compact)}", mode == :request)
        elsif old_values.is_a?(Array)
          note("#{where}: no longer limited to fixed values", false)
        end
      end

      def values(list)
        "#{list.size == 1 ? "value" : "values"} #{list.map { |v| "`#{v}`" }.join(", ")}"
      end

      def properties(a, b, label, path, mode, depth)
        old_props = hash(a["properties"])
        new_props = hash(b["properties"])
        old_required = Array(a["required"])
        new_required = Array(b["required"])
        hidden = mode == :request ? "readOnly" : "writeOnly"
        old_props.each do |name, prop|
          next if flag?(@old, prop, hidden)

          where = at(label, child(path, name))
          if !new_props.key?(name) || flag?(@new, new_props[name], hidden)
            note("#{where}: field removed", true)
            next
          end
          required_change(name, old_required, new_required, where, mode)
          schema(prop, new_props[name], label, child(path, name), mode, depth + 1)
        end
        new_props.each do |name, prop|
          next if (old_props.key?(name) && !flag?(@old, old_props[name], hidden)) || flag?(@new, prop, hidden)

          where = at(label, child(path, name))
          if mode == :request && new_required.include?(name)
            note("#{where}: new required field", true)
          else
            note("#{where}: field added", false)
          end
        end
      end

      def required_change(name, old_required, new_required, where, mode)
        if mode == :request && new_required.include?(name) && !old_required.include?(name)
          note("#{where}: now required", true)
        elsif mode == :response && old_required.include?(name) && !new_required.include?(name)
          note("#{where}: no longer always present", true)
        end
      end

      def child(path, name)
        path.empty? ? name : "#{path}.#{name}"
      end

      def variants(a, b, where)
        %w[oneOf anyOf].each do |keyword|
          old_count = Array(a[keyword]).count { |v| !null_schema?(@old, v) }
          new_count = Array(b[keyword]).count { |v| !null_schema?(@new, v) }
          if new_count < old_count
            note("#{where}: #{old_count - new_count} #{keyword} variant(s) removed", true)
          elsif new_count > old_count
            note("#{where}: #{new_count - old_count} #{keyword} variant(s) added", false)
          end
        end
      end

      def flag?(doc, prop, flag)
        return true if prop.is_a?(Hash) && prop[flag] == true

        target = doc.expand(prop)
        target.is_a?(Hash) && target[flag] == true
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

      # A coarse type name; an empty string means any type.
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
        when "string" then if %w[date date-time
                                 binary].include?(schema["format"])
                             "string(#{schema["format"]})"
                           else
                             "string"
                           end
        when "integer", "number", "boolean", "array" then type
        else object_kind(schema, type)
        end
      end

      def object_kind(schema, type)
        return "" unless type == "object" || schema["properties"].is_a?(Hash)

        extra = schema["additionalProperties"]
        props = hash(schema["properties"])
        props.empty? && extra.is_a?(Hash) && !extra.empty? ? "map" : "object"
      end

      def objectish?(schema)
        schema.is_a?(Hash) && (schema["type"] == "object" || !hash(schema["properties"]).empty?)
      end

      # +schema+ resolved, with allOf parts merged and object oneOf/anyOf variants merged
      # into one object (the properties of all, the required fields of every variant).
      def flatten(doc, schema, depth = 0)
        schema = doc.expand(schema)
        return schema if !schema.is_a?(Hash) || depth > MAX_DEPTH

        parts = schema["allOf"]
        return merge_all_of(doc, schema, parts, depth) if parts.is_a?(Array) && !parts.empty?

        keyword = %w[oneOf anyOf].find { |k| schema[k].is_a?(Array) && !schema[k].empty? }
        return schema unless keyword

        merge_variants(doc, schema, keyword, depth)
      end

      def merge_all_of(doc, schema, parts, depth)
        flat = parts.map { |p| flatten(doc, p, depth + 1) }
        rest = schema.except("allOf")
        return flat.first.merge(rest) if flat.size == 1 && flat.first.is_a?(Hash) && !objectish?(flat.first)

        props = {}
        required = []
        (flat + [rest]).each do |part|
          next unless part.is_a?(Hash)

          props.merge!(hash(part["properties"]))
          required |= Array(part["required"])
        end
        out = rest.merge("type" => "object", "properties" => props, "required" => required)
        out["nullable"] = true if flat.any? { |p| p.is_a?(Hash) && p["nullable"] == true }
        out
      end

      def merge_variants(doc, schema, keyword, depth)
        flat = schema[keyword].reject { |v| null_schema?(doc, v) }.map { |v| flatten(doc, v, depth + 1) }
        rest = schema.except("oneOf", "anyOf")
        nullable = schema[keyword].size != flat.size
        if flat.size == 1 && flat.first.is_a?(Hash)
          out = flat.first.merge(rest)
          out["nullable"] = true if nullable
          return out
        end
        return schema unless !flat.empty? && flat.all? { |v| objectish?(v) }

        props = {}
        flat.each { |v| hash(v["properties"]).each { |name, prop| props[name] ||= prop } }
        required = flat.map { |v| Array(v["required"]) }.reduce(:&) || []
        out = rest.merge("type" => "object", "properties" => props, "required" => required)
        out["nullable"] = true if nullable
        out
      end
    end
  end
end
