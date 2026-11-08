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

