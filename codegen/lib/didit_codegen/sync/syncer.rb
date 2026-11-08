# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # One spec sync run over a repository checkout.
    class Syncer
      include MethodChanges
      include OperationChanges

      # +downloads+ maps each file of UPSTREAM to the downloaded bytes; +date+ is YYYY-MM-DD;
      # +now+ is the fetch time recorded in SOURCE.json. With +generate+ false the SDK is not
      # regenerated (Sync.classify).
      def initialize(root, downloads, date:, now:, generate: true)
        @root = root
        @openapi = File.join(root, "openapi")
        @downloads = UPSTREAM.keys.to_h { |file| [file, downloads.fetch(file).b] }
        @date = date
        @now = now
        @generate = generate
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
        Result.new(changed: true, report: @report, generator_error: (regenerate if @generate))
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
        @old_ops = operations(@old_docs, GENERATED)
        @new_ops = operations(@new_docs, GENERATED)
        @old_hand_written = operations(@old_docs, UPSTREAM.keys - GENERATED)
        @new_hand_written = operations(@new_docs, UPSTREAM.keys - GENERATED)
      end

      def parse_old(bytes)
        bytes.nil? ? {} : JSON.parse(bytes.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        {}
      end

      def operations(docs, files)
        files.each_with_object({}) { |file, out| out.merge!(docs.fetch(file).operations(file, PREFIXES.fetch(file))) }
      end

      def analyse
        drop_overlay_entries
        expire_entries
        classify_methods
        drop_returning_entries
        describe_other_operations
        describe_changed_operations
        describe_hand_written_operations
        describe_schemas
        @report.observable = observable?
      end

      # Whether a caller can observe the sync (docs/DESIGN.md section 3.1), decided like
      # sdk-python: an operation added or removed, an SDK naming that changed, or a changed
      # document that differs in more than its documentation (Schemas.observable). A breaking
      # change makes the sync feat too (Report#type).
      def observable?
        return true if @old_ops.keys.sort != @new_ops.keys.sort
        return true if @old_hand_written.keys.sort != @new_hand_written.keys.sort
        return true if (@old_ops.keys & @new_ops.keys).any? { |key| naming_differs?(old_naming(key), new_naming(key)) }

        hand_written = (@old_hand_written.keys & @new_hand_written.keys).any? do |key|
          naming_differs?(@old_hand_written[key].upstream_naming, @new_hand_written[key].upstream_naming)
        end
        hand_written || (UPSTREAM.keys - @unchanged).any? do |file|
          Schemas.observable(@old_docs[file].data) != Schemas.observable(@new_docs[file].data)
        end
      end

      def naming_differs?(before, after)
        JsonText.normalize(before) != JsonText.normalize(after)
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

      # Runs the generator on the updated openapi/; returns its error, if any. The documents are
      # already written, so a crash (a schema shape the generator does not handle yet) is
      # reported the same way as a generator error, with exit code 2 and Action needed.
      def regenerate
        @report.generated = Generator.new(@root).write.size
        nil
      rescue Error => e
        @report.action_needed = [e.message, suggestions]
        e
      rescue StandardError => e
        crash = Error.new("The generator crashed: #{e.class}: #{e.message}\n" \
                          "#{Array(e.backtrace).first(5).map { |line| "  #{line}" }.join("\n")}")
        @report.action_needed = [crash.message, suggestions]
        crash
      end
    end
  end
end
