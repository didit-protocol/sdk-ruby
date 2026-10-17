# frozen_string_literal: true

module DiditCodegen
  module Sync
    # Operations and schemas that changed upstream, field by field. Mixed into Syncer.
    module OperationChanges
      private

      # Added and removed operations that have no server method (server methods are
      # reported by MethodChanges), and the operations that have no SDK naming at all.
      def describe_other_operations
        (@new_ops.keys - @old_ops.keys).sort.each do |key|
          naming = new_naming(key)
          if naming.nil?
            @report.added << "`#{key}`: **no SDK naming**; add an entry to `openapi/overlay.json` (see Action needed)"
          elsif JsonText.ident(naming).nil?
            @report.added << "`#{key}`: not exposed by the server SDKs (auth `#{naming["auth"]}`)"
          end
        end
        (@old_ops.keys - @new_ops.keys).sort.each do |key|
          next if JsonText.ident(old_naming(key))

          @report.removed << "`#{key}`: not exposed by the server SDKs"
        end
      end

      def describe_changed_operations
        comparers = {}
        (@old_ops.keys & @new_ops.keys).sort.each do |key|
          old_ref = @old_ops[key]
          new_ref = @new_ops[key]
          next if @unchanged.include?(new_ref.file)

          exact, structural = comparers[new_ref.file] ||= [
            Comparer.new(old_ref.doc, new_ref.doc, ignore_docs: false),
            Comparer.new(old_ref.doc, new_ref.doc, ignore_docs: true)
          ]
          old_parts = parts(old_ref)
          new_parts = parts(new_ref)
          next if parts_equal?(exact, old_parts, new_parts)

          describe_change(key, old_ref, new_ref, docs_only: parts_equal?(structural, old_parts, new_parts))
        end
      end

      def describe_change(key, old_ref, new_ref, docs_only:)
        name = JsonText.ident(new_naming(key))
        label = "`#{key}`#{name ? " (`#{name}`)" : " (not exposed by the server SDKs)"}"
        notes = Details.new(old_ref.doc, new_ref.doc).operation(old_ref, new_ref)
        if notes.empty?
          what = docs_only ? "documentation only" : "details changed (formats, limits, error responses or similar)"
          @report.changed << "#{label}: #{what}"
          return
        end
        breaking = name ? notes.select(&:last) : []
        @report.changed << nested("#{label}#{" **breaking**" unless breaking.empty?}", notes, exposed: !name.nil?)
        breaking.each { |text, _| @report.breaking << "`#{name}` (`#{key}`): #{text}" }
      end

      # What an operation sends and receives, plus everything else it documents.
      def parts(ref)
        {
          parameters: ref.parameters, body: ref.op["requestBody"], responses: ref.op["responses"],
          rest: ref.op.reject { |k, _| %w[parameters requestBody responses x-didit-sdk].include?(k) }
        }
      end

      def parts_equal?(comparer, a, b)
        comparer.equal?(a[:parameters], b[:parameters], names: true) && comparer.equal?(a[:body], b[:body]) &&
          comparer.equal?(a[:responses], b[:responses], names: true) && comparer.equal?(a[:rest], b[:rest])
      end

      def describe_schemas
        UPSTREAM.each_key do |file|
          next if @unchanged.include?(file)

          old_doc = @old_docs[file]
          new_schemas = @new_docs[file].schemas
          old_schemas = old_doc.schemas
          (new_schemas.keys - old_schemas.keys).sort.each { |n| @report.schemas << "`#{n}` added (#{file})" }
          removed_schemas(file, old_schemas.keys - new_schemas.keys)
          (old_schemas.keys & new_schemas.keys).sort.each do |n|
            next if old_schemas[n] == new_schemas[n]

            docs_only = Sync.strip_docs(old_schemas[n]) == Sync.strip_docs(new_schemas[n])
            @report.schemas << "`#{n}` changed (#{file})#{", documentation only" if docs_only}"
          end
        end
      end

      def removed_schemas(file, names)
        return if names.empty?

        used = @old_docs[file].reachable_schemas(old_server_nodes(file))
        names.sort.each do |n|
          @report.schemas << "`#{n}` removed (#{file})"
          next unless used.include?(n)

          @report.breaking << "schema `#{n}` (#{file}) was removed; the SDK type generated from it goes away"
        end
      end

      def old_server_nodes(file)
        @old_ops.values.select { |ref| ref.file == file && JsonText.ident(old_naming(ref.key)) }
                .flat_map { |ref| [ref.op, ref.item["parameters"]] }
      end

      # Overlay entries to suggest for operations without SDK naming: the naming they had
      # before when they lost it, otherwise a guess from the path.
      def suggestions
        @new_ops.keys.sort.each_with_object({}) do |key, out|
          next unless new_naming(key).nil?

          before = @old_ops.key?(key) ? old_naming(key) : nil
          out[key] = before ? JsonText.normalize(before) : guess(@new_ops[key])
        end
      end

      def guess(ref)
        account = ref.file == "account.json"
        scoped = !account && ref.path.start_with?(APPLICATION_PREFIX)
        segments = (scoped ? ref.path.delete_prefix(APPLICATION_PREFIX) : ref.path).split("/").reject(&:empty?)
        segments.shift if segments.first&.match?(/\Av\d+\z/)
        names = segments.reject { |s| s.start_with?("{") }.map { |s| Naming.snake(s) }
        names.unshift("account") if account && names.first != "account"
        out = {
          "auth" => account ? "account_token" : "api_key", "method" => guess_method(ref, segments),
          "resource" => names.empty? ? "root" : names.join("."), "server" => true
        }
        scoped ? out.merge("scope" => "application").sort.to_h : out
      end

      def guess_method(ref, segments)
        case ref.http_method
        when "get" then segments.last.to_s.start_with?("{") ? "retrieve" : "list"
        when "post" then "create"
        when "put", "patch" then "update"
        when "delete" then "delete"
        else ref.http_method
        end
      end
    end

    # +node+ without documentation keys; keys inside NAME_MAPS (property names) stay.
    def self.strip_docs(node, names: false)
      case node
      when Hash
        node.each_with_object({}) do |(k, v), out|
          next if !names && (DOC_KEYS.include?(k) || k.start_with?("x-"))

          out[k] = strip_docs(v, names: !names && NAME_MAPS.include?(k))
        end
      when Array then node.map { |v| strip_docs(v) }
      else node
      end
    end
  end
end
