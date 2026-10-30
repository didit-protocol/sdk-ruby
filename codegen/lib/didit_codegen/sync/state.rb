# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # The hand-maintained files of openapi/ the sync reads and rewrites: overlay.json,
    # deprecated-operations.json and SOURCE.json. Each is written back in its own layout,
    # and only when its content changed.
    class State
      # Key order of a deprecated-operations.json entry; the bulky operation goes last.
      ENTRY_ORDER = %w[
        reason operation_key x-didit-sdk replacement since deprecated_since remove_in note operation
      ].freeze

      # +overlay+ is the live operations map (entries are deleted from it); +original_overlay+
      # is a copy as it was before the sync. +entries+ maps "resource.method" to an entry.
      attr_reader :overlay, :original_overlay, :entries

      def initialize(openapi_dir)
        @dir = openapi_dir
        @overlay_text = read("overlay.json") or raise InputError, "openapi/overlay.json is missing."
        @overlay_file = parse("overlay.json", @overlay_text)
        @overlay_file["operations"] = {} unless @overlay_file["operations"].is_a?(Hash)
        @overlay = @overlay_file["operations"]
        @original_overlay = JSON.parse(JSON.generate(@overlay))
        @deprecated_text = read(DEPRECATED_FILE)
        @deprecated_file = @deprecated_text ? parse(DEPRECATED_FILE, @deprecated_text) : {}
        @entries = @deprecated_file["methods"].is_a?(Hash) ? @deprecated_file["methods"] : {}
        @source_text = read("SOURCE.json")
        @source = @source_text ? parse("SOURCE.json", @source_text) : {}
      end

      # Writes the upstream copies that changed, SOURCE.json, and overlay.json and
      # deprecated-operations.json when their content changed.
      def write(downloads, changed, fetched_at)
        changed.each { |file| File.binwrite(File.join(@dir, file), downloads.fetch(file)) }
        write_source(downloads, changed, fetched_at)
        overlay = JsonText.dump_like(@overlay_text, @overlay_file)
        write_text("overlay.json", overlay) if overlay != @overlay_text
        return if @entries.empty? && @deprecated_text.nil?

        deprecated = JsonText.dump_like(@deprecated_text, deprecated_file)
        write_text(DEPRECATED_FILE, deprecated) if deprecated != @deprecated_text
      end

      private

      def read(file)
        path = File.join(@dir, file)
        File.exist?(path) ? File.read(path, encoding: "UTF-8") : nil
      end

      def parse(file, text)
        data = JSON.parse(text)
        raise InputError, "openapi/#{file} is not a JSON object." unless data.is_a?(Hash)

        data
      rescue JSON::ParserError => e
        raise InputError, "openapi/#{file} is not valid JSON (#{e.message[0, 120]})."
      end

      def write_text(file, text)
        File.write(File.join(@dir, file), text, mode: "wb")
      end

      # Keeps the key order, the other entries (webhook-vectors.json) and the layout.
      def write_source(downloads, changed, fetched_at)
        changed.each do |file|
          entry = @source[file].is_a?(Hash) ? @source[file] : {}
          entry["url"] = UPSTREAM.fetch(file)
          entry["sha256"] = Sync.sha256(downloads.fetch(file))
          entry["fetched_at"] = fetched_at
          @source[file] = entry
        end
        write_text("SOURCE.json", JsonText.dump_like(@source_text, @source))
      end

      def deprecated_file
        out = { "description" => DEPRECATED_DESCRIPTION }.merge(@deprecated_file)
        out["methods"] = @entries.sort.to_h { |name, entry| [name, ordered(entry)] }
        out
      end

      def ordered(entry)
        return entry unless entry.is_a?(Hash)

        known = ENTRY_ORDER.select { |k| entry.key?(k) }
        (known + (entry.keys - ENTRY_ORDER).sort).to_h { |k| [k, entry[k]] }
      end
    end
  end
end
