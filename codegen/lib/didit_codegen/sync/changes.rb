# frozen_string_literal: true

module DiditCodegen
  module Sync
    # Operations and schemas that changed upstream, field by field. Mixed into Syncer.
    #
    # The changes of an operation count only when a server method calls it before and after
    # the sync: those of an operation with server: false are listed, never counted
    # (docs/DESIGN.md section 3.1).
    module OperationChanges
      PART_KEYS = %w[parameters requestBody responses x-didit-sdk].freeze
      FOLLOW = "update `lib/didit/authentication.rb` and `spec/authentication/contract_spec.rb` in this pull request"

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
        changed_operations(@old_ops, @new_ops) do |key, old_ref, new_ref, docs_only|
          namings = [old_naming(key), new_naming(key)]
          describe_change(key, old_ref, new_ref, docs_only: docs_only, namings: namings)
        end
      end

      # Yields each operation of +old_ops+ and +new_ops+ that changed, and whether only its
      # documentation did.
      def changed_operations(old_ops, new_ops)
        comparers = {}
        (old_ops.keys & new_ops.keys).sort.each do |key|
          old_ref = old_ops[key]
          new_ref = new_ops[key]
          next if @unchanged.include?(new_ref.file)

          exact, structural = comparers[new_ref.file] ||= [
            Comparer.new(old_ref.doc, new_ref.doc, ignore_docs: false),
            Comparer.new(old_ref.doc, new_ref.doc, ignore_docs: true)
          ]
          old_parts = parts(old_ref)
          new_parts = parts(new_ref)
          next if parts_equal?(exact, old_parts, new_parts)

          yield key, old_ref, new_ref, parts_equal?(structural, old_parts, new_parts)
        end
      end

      # +namings+ is the operation's SDK naming before and after the sync. Its changes count
      # when each is a server operation or has no naming at all (the generator fails until it is
      # named, so the method cannot ship without them).
      def describe_change(key, old_ref, new_ref, docs_only:, namings:)
        exposed = namings.all? { |naming| naming.nil? || (naming.is_a?(Hash) && naming["server"] == true) }
        name = JsonText.ident(namings.last) || JsonText.ident(namings.first)
        label = if !exposed then "`#{key}` (not exposed by the server SDKs)"
                elsif name then "`#{key}` (`#{name}`)"
                else "`#{key}` (no SDK naming)"
                end
        changes = Details.new(old_ref.doc, new_ref.doc).operation(old_ref, new_ref)
        if changes.empty?
          what = docs_only ? "documentation only" : "details changed (formats, limits, error responses or similar)"
          @report.changed << "#{label}: #{what}"
          return
        end
        changes = changes.map(&:listed) unless exposed
        breaking = changes.select(&:breaking)
        @report.changed << nested("#{label}#{" **breaking**" unless breaking.empty?}", changes)
        breaking.each { |change| count_change(key, name, change) }
      end

      # Records a counted Change of the operation +key+, whose server method is +name+.
      def count_change(key, name, change, prefix: nil)
        prefix ||= name ? "`#{name}` (`#{key}`)" : "`#{key}`"
        @report.count("#{prefix}: #{change.text}", change.normalized(key))
      end

      # Added, removed, renamed and changed operations of a document whose module is
      # hand-written (authentication.json, docs/DESIGN.md section 10). Nothing is generated,
      # named in overlay.json or deprecated for them: spec/authentication/contract_spec.rb
      # fails until the module follows. A removed operation with server methods counts; a
      # change of its SDK naming is listed (as sdk-python does).
      def describe_hand_written_operations
        old_ops = @old_hand_written
        new_ops = @new_hand_written
        (new_ops.keys - old_ops.keys).sort.each { |key| hand_written_added(key, new_ops[key]) }
        (old_ops.keys - new_ops.keys).sort.each { |key| hand_written_removed(key, old_ops[key]) }
        (old_ops.keys & new_ops.keys).sort.each { |key| hand_written_naming(key, old_ops[key], new_ops[key]) }
        changed_operations(old_ops, new_ops) do |key, old_ref, new_ref, docs_only|
          describe_change(key, old_ref, new_ref, docs_only: docs_only,
                                                 namings: [old_ref.upstream_naming, new_ref.upstream_naming])
        end
      end

      def hand_written_added(key, ref)
        names = hand_written_methods(ref)
        @report.added << if names.empty?
                           "`#{key}`: not exposed by the server SDKs"
                         else
                           "`#{key}`: #{code_list(names)}; #{FOLLOW}"
                         end
      end

      def hand_written_removed(key, ref)
        names = hand_written_methods(ref)
        return @report.removed << "`#{key}`: not exposed by the server SDKs" if names.empty?

        @report.removed << "`#{key}` (#{code_list(names)}): #{FOLLOW}"
        methods = names.size == 1 ? "its method" : "its methods"
        @report.count("`#{key}` (#{code_list(names)}) was removed upstream, and #{methods} with it",
                      "#{key}: operation removed")
      end

      def hand_written_naming(key, old_ref, new_ref)
        before = old_ref.upstream_naming
        after = new_ref.upstream_naming
        return if JsonText.normalize(before) == JsonText.normalize(after)

        gone = hand_written_methods(old_ref) - hand_written_methods(new_ref)
        gone = gone.empty? ? "" : "; no longer SDK methods: #{code_list(gone)}"
        @report.naming << "`#{key}`: `x-didit-sdk` changed from `#{JsonText.compact(before)}` to " \
                          "`#{JsonText.compact(after)}`#{gone}; #{FOLLOW}"
      end

      # The server method of a hand-written operation and those of its variants.
      def hand_written_methods(ref)
        naming = ref.upstream_naming
        name = JsonText.ident(naming)
        return [] if name.nil?

        variants = Array(naming["variants"]).filter_map do |variant|
          "#{naming["resource"]}.#{variant["method"]}" if variant.is_a?(Hash) && variant["method"].is_a?(String)
        end
        [name, *variants].uniq
      end

      def code_list(names)
        names.map { |name| "`#{name}`" }.join(", ")
      end

      # What an operation sends and receives, plus everything else it documents.
      def parts(ref)
        {
          parameters: ref.parameters, body: ref.op["requestBody"], responses: ref.op["responses"],
          rest: ref.op.except(*PART_KEYS)
        }
      end

      def parts_equal?(comparer, before, after)
        comparer.equal?(before[:parameters], after[:parameters], names: true) &&
          comparer.equal?(before[:body], after[:body]) &&
          comparer.equal?(before[:responses], after[:responses], names: true) &&
          comparer.equal?(before[:rest], after[:rest])
      end

      def describe_schemas
        UPSTREAM.each_key do |file|
          next if @unchanged.include?(file)

          old_doc = @old_docs[file]
          new_schemas = @new_docs[file].schemas
          old_schemas = old_doc.schemas
          added = new_schemas.keys - old_schemas.keys
          removed = old_schemas.keys - new_schemas.keys
          added.sort.each { |n| @report.schemas << "`#{n}` added (#{file})" }
          removed_schemas(file, removed)
          (old_schemas.keys & new_schemas.keys).sort.each do |n|
            next if old_schemas[n] == new_schemas[n]

            docs_only = Sync.strip_docs(old_schemas[n]) == Sync.strip_docs(new_schemas[n])
            @report.schemas << "`#{n}` changed (#{file})#{", documentation only" if docs_only}"
          end
        end
      end

      def removed_schemas(file, names)
        return if names.empty?

        # Listed, not counted (docs/DESIGN.md section 3.1): the operations that used it say what
        # changed for each of their fields.
        used = @old_docs[file].reachable_schemas(old_server_nodes(file))
        names.sort.each do |n|
          type = "; the SDK type generated from it goes away" if used.include?(n)
          @report.schemas << "`#{n}` removed (#{file})#{type}"
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
        segments = path_segments(ref)
        names = segments.reject { |s| s.start_with?("{") }.map { |s| Naming.snake(s) }
        # The top-level resource the named operations under the same first path segment use
        # ("/v3/session/..." is "sessions").
        names[0] = known_roots.fetch(names[0], names[0]) unless names.empty?
        names.unshift("account") if account && names.first != "account"
        out = {
          "auth" => account ? "account_token" : "api_key", "method" => guess_method(ref, segments),
          "resource" => names.empty? ? "root" : names.join("."), "server" => true
        }
        scoped ? out.merge("scope" => "application").sort.to_h : out
      end

      # The path below the version and the application scope prefix, split at "/".
      def path_segments(ref)
        path = ref.path.start_with?(APPLICATION_PREFIX) ? ref.path.delete_prefix(APPLICATION_PREFIX) : ref.path
        segments = path.split("/").reject(&:empty?)
        segments.shift if segments.first&.match?(/\Av\d+\z/)
        segments
      end

      # First path segment (snake_case) => the first resource segment its named server
      # operations use, for verification.json.
      def known_roots
        @known_roots ||= @new_ops.values.each_with_object({}) do |ref, out|
          name = ref.file == "verification.json" ? JsonText.ident(new_naming(ref.key)) : nil
          first = path_segments(ref).first
          next if name.nil? || first.nil? || first.start_with?("{")

          out[Naming.snake(first)] ||= name.split(".").first
        end
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
  end
end
