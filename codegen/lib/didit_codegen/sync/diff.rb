# frozen_string_literal: true

module DiditCodegen
  module Sync
    # Keys that only document a schema or an operation.
    DOC_KEYS = %w[description summary title example examples externalDocs tags].freeze
    # Keys whose value maps names (property names, media types, status codes) to objects.
    # Inside them every key is a name, never a keyword: a property called "title" is a field.
    NAME_MAPS = %w[
      properties patternProperties paths schemas responses parameters requestBodies headers securitySchemes content
      encoding variables mapping links callbacks x-webhooks
    ].freeze
    PARAMETER_LOCATIONS = %w[path query header cookie].freeze
    # Kinds of the operation itself, written without "<where> <field>" (Change#normalized).
    OPERATION_KINDS = ["operation removed", "body now required"].freeze

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

      # +names+ tells that the keys of +before+ and +after+ are names (see NAME_MAPS).
      def equal?(before, after, names: false)
        if before.is_a?(Hash) && after.is_a?(Hash)
          return refs_equal?(before, after) if !names && (before.key?("$ref") || after.key?("$ref"))

          keys = before.keys | after.keys
          keys = keys.reject { |k| Sync.doc_key?(k) } if @ignore_docs && !names
          keys.all? do |k|
            before.key?(k) && after.key?(k) && equal?(before[k], after[k], names: !names && NAME_MAPS.include?(k))
          end
        elsif before.is_a?(Array) && after.is_a?(Array)
          before.size == after.size && before.each_index.all? { |i| equal?(before[i], after[i]) }
        else
          before.instance_of?(after.class) && before == after
        end
      end

      private

      def refs_equal?(before, after)
        key = [before["$ref"], after["$ref"]]
        pure = (before.keys - ["$ref"]).empty? && (after.keys - ["$ref"]).empty?
        return @memo[key] if pure && @memo.key?(key)
        # A recursive schema: equal unless something else differs.
        return true if @active.key?(key)

        @active[key] = true
        result = equal?(@old.expand(before), @new.expand(after))
        @active.delete(key)
        @memo[key] = result if pure
        result
      end
    end

    # One difference of an operation. +where+ is "response", "request body", a parameter's
    # location ("query") or "operation"; +path+ is the field ("results[].name", a parameter's
    # name first, "" for a whole body); +kind+ is what the summary says. +breaking+ when
    # docs/DESIGN.md section 3.1 counts it, and then +code+ is the kind as
    # openapi/breaking-vectors.json spells it ("removed", "type string -> object").
    Change = Struct.new(:where, :path, :kind, :breaking, :code) do
      # Where the change is, as the summary and the release notes say it.
      def self.target(where, path)
        return "#{where} parameter `#{path}`" if PARAMETER_LOCATIONS.include?(where)

        path.empty? ? where : "#{where} `#{path}`"
      end

      def text
        "#{Change.target(where, path)}: #{kind}"
      end

      # The line openapi/breaking-vectors.json compares in all seven SDKs:
      # "<METHOD> <path> <where> <field>: <kind>", without <field> for a whole body and without
      # "<where> <field>" for the operation itself.
      def normalized(operation)
        return "#{operation}: #{code}" if OPERATION_KINDS.include?(code)

        "#{operation} #{[where, path].reject(&:empty?).join(" ")}: #{code}"
      end

      def listed
        breaking ? Change.new(where, path, kind, false, "") : self
      end
    end

    # The differences between two versions of an operation (docs/DESIGN.md section 3.1), step
    # for step like sdk-python's codegen/spec_sync.py, so that every server SDK counts the same
    # changes: its parameters, its request body, and what the method returns, every 2xx body.
    # Schemas are compared dereferenced (Doc#dereference).
    #
    # Counted, in requests and responses: a type change in either direction (a typed string
    # format and "any" included), a removed field, parameter, enum value or union variant.
    # Only in a response: a value that can now be null and a field that is no longer required.
    # Only in a request: a new required parameter or field, an optional one becoming required
    # and a body becoming required. Union variants are paired with the variants they became,
    # and their changes follow the same rules. Everything else is listed, not counted.
    #
    # One rule is the Ruby SDK's own: the generated code leaves out read-only fields of a
    # request and write-only fields of a response, so a field that becomes one counts as
    # removed, and one that stops being one is added.
    class Details
      include Schemas

      # Where a request body or response has no content at all: nothing to compare with, unlike
      # {}, which allows any value. Compared by identity.
      NO_SCHEMA = {}.freeze
      PATHS = [%w[items []], %w[additionalProperties {}]].freeze

      def initialize(old, new)
        @old = old
        @new = new
        @shapes = {}.compare_by_identity
      end

      # @return [Array<Change>] every difference of +old_ref+ and +new_ref+, once each
      def operation(old_ref, new_ref)
        found = []
        parameters(parameter_map(@old, old_ref), parameter_map(@new, new_ref), found)
        request_body(old_ref.op, new_ref.op, found)
        responses(successes(@old, old_ref.op), successes(@new, new_ref.op), found)
        if old_ref.op["deprecated"] != true && new_ref.op["deprecated"] == true
          found << change("operation", "", "marked deprecated upstream")
        end
        found.uniq
      end

      private

      # A Change that counts when it has a +code+.
      def change(where, path, kind, code = nil)
        Change.new(where, path, kind, !code.nil?, code.to_s)
      end

      # Path-item and operation parameters by [location, name] (the operation wins), dereferenced.
      def parameter_map(doc, ref)
        raw = list(ref.item["parameters"]) + list(ref.op["parameters"])
        doc.dereference(raw, ref_titles: false).grep(Hash).to_h do |param|
          [[param["in"].to_s, param["name"].to_s], param]
        end
      end

      def parameters(old_params, new_params, found)
        (old_params.keys - new_params.keys).sort.each { |key| found << change(*key, "removed", "removed") }
        (new_params.keys - old_params.keys).sort.each do |key|
          required = new_params[key]["required"] == true
          found << change(*key, required ? "added (required)" : "added", ("now required" if required))
        end
        (old_params.keys & new_params.keys).sort.each do |key|
          was = old_params[key]["required"] == true
          now = new_params[key]["required"] == true
          found << change(*key, "now required", "now required") if now && !was
          found << change(*key, "no longer required") if was && !now
          diff_schema(present(old_params[key]["schema"], {}), present(new_params[key]["schema"], {}), *key,
                      request: true, out: found)
        end
      end

      def request_body(old_op, new_op, found)
        old_body = present(old_op["requestBody"], {})
        new_body = present(new_op["requestBody"], {})
        was = required?(@old, old_body)
        now = required?(@new, new_body)
        found << change("request body", "", "now required", "body now required") if now && !was
        found << change("request body", "", "no longer required") if was && !now
        diff_content(content(@old, old_body), content(@new, new_body), "request body", request: true, out: found)
      end

      def required?(doc, body)
        expanded = doc.expand(body)
        expanded.is_a?(Hash) && expanded["required"] == true
      end

      # The schema of each media type of a request body or response.
      def content(doc, node)
        node = doc.dereference(node, ref_titles: false)
        media = node.is_a?(Hash) ? node["content"] : nil
        return {} unless media.is_a?(Hash)

        media.each_with_object({}) do |(type, entry), out|
          out[type] = present(entry["schema"], {}) if entry.is_a?(Hash)
        end
      end

      # The content of each 2xx response, by status.
      def successes(doc, op)
        responses = present(op["responses"], {})
        return {} unless responses.is_a?(Hash)

        responses.keys.map(&:to_s).sort.select { |s| s.start_with?("2") }.to_h { |s| [s, content(doc, responses[s])] }
      end

      # Compares a body per media type; when none is shared, the first against the first, so
      # that a body that changes content type, appears or disappears is compared too.
      def diff_content(old, new, where, request:, out:)
        if !old.empty? && !new.empty? && old.keys.sort != new.keys.sort
          out << change(where, "", "content type #{old.keys.sort.join(", ")} -> #{new.keys.sort.join(", ")}")
        end
        pairs = (old.keys & new.keys).sort.map { |type| [type, type] }
        if pairs.empty? && !(old.empty? && new.empty?)
          old = { "" => NO_SCHEMA } if old.empty?
          new = { "" => NO_SCHEMA } if new.empty?
          pairs = [[old.keys.min, new.keys.min]]
        end
        pairs.each { |before, after| diff_schema(old[before], new[after], where, request: request, out: out) }
      end

      # Every 2xx status both have, with a body on both sides or on neither; when the only
      # success status changed (200 to 201), the old body against the new one. The other
      # statuses, and a body that appeared or disappeared, change what the method returns.
      def responses(old, new, found)
        statuses = old.keys.select { |s| new.key?(s) && old[s].empty? == new[s].empty? }.map { |s| [s, s] }
        if statuses.empty? && old.size == 1 && new.size == 1 && old.values.first.empty? == new.values.first.empty?
          statuses = [[old.keys.first, new.keys.first]]
          found << change("response", "", "status #{old.keys.first} -> #{new.keys.first}")
        else
          compared = statuses.map(&:first)
          status_changes(old, new, old.keys - compared, new.keys - compared, found)
        end
        statuses.each { |before, after| diff_content(old[before], new[after], "response", request: false, out: found) }
      end

      # The success statuses not compared body by body: +removed+ (only +old+ has them, or their
      # body disappeared) and +added+ (only +new+ has them, or their body appeared). The method
      # returns every 2xx body, nullable when one has none: a status without a body makes it
      # nullable, and a removed status whose body no other one returns removes a type from it,
      # null when no body is left.
      def status_changes(old, new, removed, added, found)
        added.each do |status|
          if new[status].empty? && !bodies(old).empty? && !returns_null?(old)
            label = old.key?(status) ? "lost its body" : "has no body"
            found << change("response", "", "can now be null (status #{status} #{label})", "can now be null")
          elsif !old.key?(status)
            other = !new[status].empty? && !bodies(old).include?(shape(new[status], names: true))
            found << change("response", "", "status #{status} added#{" with another body" if other}")
          end
        end
        removed.each { |status| removed_status(old, new, status, found) }
      end

      def removed_status(old, new, status, found)
        what = if new.key?(status) then old[status].empty? ? "now has a body" : "lost its body"
               else "removed"
               end
        found << if old[status].empty? && !bodies(new).empty? && !returns_null?(new)
                   change("response", "", "can no longer be null (status #{status} #{what})")
                 elsif !old[status].empty? && !bodies(new).include?(shape(old[status], names: true))
                   change("response", "", "type changed: status #{status} #{what}, and no other status returns " \
                                          "its body", "type #{status_types(old)} -> #{status_types(new)}")
                 else
                   change("response", "", "status #{status} #{what}")
                 end
      end

      def bodies(responses)
        responses.values.reject(&:empty?).map { |media| shape(media, names: true) }
      end

      def returns_null?(responses)
        responses.values.any?(&:empty?)
      end

      # The types of every distinct 2xx body, "null" when there is none.
      def status_types(responses)
        distinct = {}
        responses.each_value do |media|
          next if media.empty?

          distinct[shape(media, names: true)] ||= media.fetch("application/json") { media[media.keys.min] }
        end
        names = union_names(distinct.values)
        names.empty? ? "null" : names
      end

      # Appends a Change to +out+ for every difference between two dereferenced schemas.
      def diff_schema(old, new, where, path = "", request:, out:, depth: 0)
        return if depth > MAX_DEPTH || shape_of(old) == shape_of(new)

        start = out.size
        # A request body that appears or disappears is compared field by field, not as a type
        # change (a response's is a success status change, status_changes).
        both = !old.equal?(NO_SCHEMA) && !new.equal?(NO_SCHEMA)
        old = {} unless old.is_a?(Hash)
        new = {} unless new.is_a?(Hash)
        nullability(old, new, where, path, request, out)
        old = single(old)
        new = single(new)
        return if both && type_changed?(old, new, where, path, request: request, out: out, depth: depth)

        enum_changes(old, new, where, path, out)
        fields(old, new, where, path, request: request, out: out, depth: depth)
        PATHS.each do |key, suffix|
          next unless old[key].is_a?(Hash) || new[key].is_a?(Hash)

          diff_schema(mapping(old[key]), mapping(new[key]), where, path + suffix, request: request, out: out,
                                                                                  depth: depth + 1)
        end
        diff_variants(old, new, where, path, request: request, out: out, depth: depth, retyped: false)
        return unless out.size == start

        out << change(where, path, "other constraints changed (format, pattern, limits or default)")
      end

      def shape_of(schema)
        return shape(schema) unless schema.is_a?(Hash) || schema.is_a?(Array)

        @shapes[schema] ||= shape(schema)
      end

      def mapping(value)
        value.is_a?(Hash) ? value : {}
      end

      def nullability(old, new, where, path, request, out)
        if nullable?(new) && !nullable?(old)
          # A request that accepts null only widens what a caller may send.
          out << change(where, path, "can now be null", ("can now be null" unless request))
        elsif nullable?(old) && !nullable?(new)
          out << change(where, path, request ? "no longer accepts null" : "can no longer be null")
        end
      end

      # Notes a type change, "any" against a type included; true when there is one.
      def type_changed?(old, new, where, path, request:, out:, depth:)
        old_kinds = kinds(old)
        new_kinds = kinds(new)
        before = type_names(old, old_kinds)
        after = type_names(new, new_kinds)
        return false if (old_kinds.empty? && new_kinds.empty?) || before == after

        code = "type #{type_names(old, old_kinds, "|")} -> #{type_names(new, new_kinds, "|")}"
        out << change(where, path, "type changed from #{before} to #{after}", code)
        # A union's variants can change too, also when an untyped variant made it "any"; the
        # type change already covers those removed. A schema untyped as a whole has none.
        if (!old_kinds.empty? || !variants(old).empty?) && (!new_kinds.empty? || !variants(new).empty?)
          diff_variants(old, new, where, path, request: request, out: out, depth: depth, retyped: true)
        end
        true
      end

      def enum_changes(old, new, where, path, out)
        old_enum = enum_values(old)
        new_enum = enum_values(new)
        if old_enum && new_enum
          (old_enum - new_enum).each do |value|
            kind = "enum value #{dump(value)} removed"
            out << change(where, path, kind, kind)
          end
          added = new_enum - old_enum
          out << change(where, path, "enum values added #{dump_list(added)}") unless added.empty?
        elsif new_enum
          out << change(where, path, "now limited to #{dump_list(new_enum)}")
        elsif old_enum
          out << change(where, path, "no longer limited to fixed values")
        end
      end

      def dump(value)
        JSON.generate(value)
      end

      def dump_list(values)
        "[#{values.map { |value| dump(value) }.join(", ")}]"
      end

      def fields(old, new, where, path, request:, out:, depth:)
        old_props, old_required = object_props(old)
        new_props, new_required = object_props(new)
        # A union's fields live in its variants (diff_variants).
        return unless (!old_props.empty? && !new_props.empty?) || (variants(old).empty? && variants(new).empty?)

        (old_props.keys - new_props.keys).sort.each do |name|
          out << change(where, join(path, name), "removed", "removed")
        end
        (new_props.keys - old_props.keys).sort.each do |name|
          required = request && new_required.include?(name)
          out << change(where, join(path, name), required ? "added (required)" : "added", ("now required" if required))
        end
        (old_props.keys & new_props.keys).sort.each do |name|
          at = join(path, name)
          next if visibility_changed?(old_props[name], new_props[name], where, at, request, new_required.include?(name),
                                      out)

          required_change(old_required.include?(name), new_required.include?(name), where, at, request, out)
          diff_schema(old_props[name], new_props[name], where, at, request: request, out: out, depth: depth + 1)
        end
      end

      def join(path, name)
        path.empty? ? name : "#{path}.#{name}"
      end

      def required_change(was, now, where, at, request, out)
        if now && !was
          out << change(where, at, request ? "now required" : "now always present", ("now required" if request))
        elsif was && !now
          # A response field that may be missing breaks code that reads it.
          out << change(where, at, request ? "no longer required" : "no longer always present",
                        ("no longer required" unless request))
        end
      end

      # The Ruby SDK's own rule: a field that becomes read-only in a request or write-only in a
      # response leaves the generated type (removed), one that stops being one joins it (added).
      # True when the field's visibility changed.
      def visibility_changed?(old_prop, new_prop, where, at, request, required, out)
        flag = request ? "readOnly" : "writeOnly"
        was = mapping(old_prop)[flag] == true
        now = mapping(new_prop)[flag] == true
        return false if was == now

        label = request ? "read-only" : "write-only"
        out << if now
                 change(where, at, "removed (now #{label})", "removed")
               else
                 counted = request && required
                 change(where, at, "added (#{"required, " if counted}no longer #{label})", ("now required" if counted))
               end
        true
      end

      # Compares two unions variant by variant; a plain schema is a union of one, so that
      # [X, null] against X loses no variant and X against [X', Y] compares X with X'. A variant
      # added or removed never hides a change inside the others.
      def diff_variants(old, new, where, path, request:, out:, depth:, retyped:)
        old_variants = variants(old).then { |found| found.empty? ? [old] : found }
        new_variants = variants(new).then { |found| found.empty? ? [new] : found }
        return if old_variants.size == 1 && new_variants.size == 1

        keyword = union_keyword(new) || union_keyword(old)
        pairs, removed, added = pair_variants(old_variants, new_variants)
        pairs.each do |i, j|
          at = new_variants.size > 1 ? "#{path}(#{positions(new)[j]})" : path
          # The fields the union requires are required in each variant too.
          diff_schema(with_required(old_variants[i], old), with_required(new_variants[j], new), where, at,
                      request: request, out: out, depth: depth + 1)
          before, after = [old_variants[i], new_variants[j]].map { |v| variant_type_name(v) || "a numbered name" }
          # The variant's title names its generated type, which gets another name.
          out << change(where, at, "variant type renamed from #{before} to #{after}") if before != after
        end
        if !removed.empty? && !retyped
          out << change(where, path, "type changed: #{removed.size} #{keyword} variant(s) removed",
                        "type #{union_names(old_variants)} -> #{union_names(new_variants)}")
        end
        out << change(where, path, "#{added.size} #{keyword} variant(s) added") unless added.empty?
        order = pairs.sort.map(&:last)
        out << change(where, path, "#{keyword} variants reordered") if order != order.sort
      end
    end
  end
end
