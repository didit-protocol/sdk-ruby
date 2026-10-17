# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # One spec sync run over a repository checkout.
    class Syncer
      include MethodChanges
      include OperationChanges

      # +downloads+ maps "verification.json" and "account.json" to the downloaded bytes;
      # +date+ is YYYY-MM-DD; +now+ is the fetch time recorded in SOURCE.json.
      def initialize(root, downloads, date:, now:)
        @root = root
        @openapi = File.join(root, "openapi")
        @downloads = UPSTREAM.keys.to_h { |file| [file, downloads.fetch(file).b] }
        @date = date
        @now = now
      end

      # @return [Result]
      # @raise [InputError] when a download or a local file is unusable; nothing is written then
      def run
        new_data = @downloads.to_h { |file, bytes| [file, Sync.check_document(file, bytes)] }
        old_bytes = UPSTREAM.keys.to_h { |file| [file, read_bytes(file)] }
        changed = UPSTREAM.keys.reject { |file| old_bytes[file] == @downloads[file] }
        return Result.new(changed: false) if changed.empty?

        prepare(old_bytes, new_data, changed)
        analyse
        @state.write(@downloads, changed, @now.getutc.strftime("%Y-%m-%dT%H:%M:%SZ"))
        Result.new(changed: true, report: @report, generator_error: regenerate)
      end

      private

      def read_bytes(file)
        path = File.join(@openapi, file)
        File.exist?(path) ? File.binread(path) : nil
      end

      def prepare(old_bytes, new_data, changed)
        @version = Sync.read_version(@root)
        @remove_in = Sync.next_minor(@version)
        @state = State.new(@openapi)
        @report = Report.new(@date)
        @unchanged = UPSTREAM.keys - changed
        @fresh = []
        UPSTREAM.each do |file, url|
          @report.add_file(file, url, Sync.sha256(old_bytes[file]), Sync.sha256(@downloads[file]))
        end
        @old_docs = UPSTREAM.keys.to_h { |file| [file, Doc.new(file, parse_old(old_bytes[file]))] }
        @new_docs = UPSTREAM.keys.to_h { |file| [file, Doc.new(file, new_data[file])] }
        @old_ops = operations(@old_docs)
        @new_ops = operations(@new_docs)
      end

      def parse_old(bytes)
        bytes.nil? ? {} : JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        {}
      end

      def operations(docs)
        docs.each_with_object({}) { |(file, doc), out| out.merge!(doc.operations(file, PREFIXES.fetch(file))) }
      end

      def analyse
        drop_overlay_entries
        expire_entries
        classify_methods
        drop_returning_entries
        describe_other_operations
        describe_changed_operations
        describe_schemas
      end

      def old_naming(key)
        ref = @old_ops[key]
        return nil if ref.nil?

        ref.upstream_naming || @state.original_overlay[key]
      end

      def new_naming(key)
        ref = @new_ops[key]
        return nil if ref.nil?

        ref.upstream_naming || @state.overlay[key]
      end

      # Runs the generator on the updated openapi/; returns its error, if any.
      def regenerate
        @report.generated = Generator.new(@root).write.size
        nil
      rescue Error => e
        @report.action_needed = [e.message, suggestions]
        e
      end
    end
  end
end
