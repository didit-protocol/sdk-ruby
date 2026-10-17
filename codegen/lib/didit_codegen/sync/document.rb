# frozen_string_literal: true

module DiditCodegen
  module Sync
    # One operation of an upstream document, as the spec sync sees it.
    OpRef = Struct.new(:key, :file, :doc, :path, :http_method, :op, :item, keyword_init: true) do
      # The upstream x-didit-sdk object, when the operation carries one.
      def upstream_naming
        naming = op["x-didit-sdk"]
        naming.is_a?(Hash) ? naming : nil
      end

      # Path-item and operation parameters by "<in> <name>" (the operation wins), dereferenced.
      def parameters
        out = {}
        (Array(item["parameters"]) + Array(op["parameters"])).each do |raw|
          param = doc.expand(raw)
          next unless param.is_a?(Hash) && param["in"].is_a?(String) && param["name"].is_a?(String)

          out["#{param['in']} #{param['name']}"] = param
        end
        out
      end
    end

    # A read-only view of one OpenAPI document. Unlike DiditCodegen::Document it never
    # raises: a dangling or circular $ref resolves to nil, and the generator reports it.
    class Doc
      attr_reader :name, :data

      def initialize(name, data)
        @name = name
        @data = data.is_a?(Hash) ? data : {}
      end

      # The node a local JSON pointer names, or nil.
      def target(ref)
        return nil unless ref.is_a?(String) && ref.start_with?("#/")

        ref[2..].split("/").reduce(data) do |cur, part|
          part = part.gsub("~1", "/").gsub("~0", "~")
          if cur.is_a?(Hash) && cur.key?(part)
            cur[part]
          elsif cur.is_a?(Array) && part.match?(/\A\d+\z/) && part.to_i < cur.size
            cur[part.to_i]
          else
            return nil
          end
        end
      end

      # +node+ with its $ref chain followed; sibling keys of a $ref apply on top of the target.
      def expand(node)
        seen = []
        while node.is_a?(Hash) && node["$ref"].is_a?(String)
          ref = node["$ref"]
          return nil if seen.include?(ref)

          seen << ref
          found = target(ref)
          return nil if found.nil?

          siblings = node.except("$ref")
          node = found.is_a?(Hash) && !siblings.empty? ? found.merge(siblings) : found
        end
        node
      end

      def schemas
        found = data.dig("components", "schemas")
        found.is_a?(Hash) ? found : {}
      end

      # Every operation, keyed like DiditCodegen::Spec.key ("POST /v3/session/").
      def operations(file, prefix)
        out = {}
        paths = data["paths"].is_a?(Hash) ? data["paths"] : {}
        paths.each do |path, raw_item|
          item = expand(raw_item)
          next unless item.is_a?(Hash)

          HTTP_METHODS.each do |http_method|
            op = item[http_method]
            next unless op.is_a?(Hash)

            key = "#{prefix}#{http_method.upcase} #{path}"
            out[key] = OpRef.new(key: key, file: file, doc: self, path: path, http_method: http_method, op: op,
                                 item: item)
          end
        end
        out
      end

      # The component schema names reachable from +nodes+ through $refs.
      def reachable_schemas(nodes)
        seen = {}
        pending = nodes.dup
        until pending.empty?
          node = pending.pop
          case node
          when Array then pending.concat(node)
          when Hash
            ref = node["$ref"]
            if ref.is_a?(String) && !seen.key?(ref)
              seen[ref] = true
              pending << target(ref)
            end
            pending.concat(node.values)
          end
        end
        seen.keys.select { |ref| ref.start_with?(SCHEMA_REF) }.map { |ref| ref.delete_prefix(SCHEMA_REF) }
      end
    end
  end
end
