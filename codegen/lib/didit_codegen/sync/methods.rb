# frozen_string_literal: true

module DiditCodegen
  module Sync
    # What happened to each public SDK method (docs/DESIGN.md section 3.1: never delete one
    # silently). Mixed into Syncer.
    module MethodChanges
      private

      # Upstream x-didit-sdk wins and its overlay entry is deleted (DESIGN section 3); the
      # entries of operations removed upstream go too.
      def drop_overlay_entries
        @state.overlay.keys.sort.each do |key|
          entry = @state.overlay[key]
          ref = @new_ops[key]
          if ref.nil?
            @state.overlay.delete(key)
            @report.naming << "`#{key}`: overlay entry deleted, the operation was removed upstream"
          elsif (upstream = ref.upstream_naming)
            @state.overlay.delete(key)
            @report.naming << overlay_drop_note(key, entry, upstream)
          end
        end
      end

      def overlay_drop_note(key, entry, upstream)
        if JsonText.normalize(entry) == JsonText.normalize(upstream)
          "`#{key}`: overlay entry deleted, upstream carries the same `x-didit-sdk`"
        else
          "`#{key}`: overlay entry deleted, upstream `x-didit-sdk` differs and wins: " \
            "`#{JsonText.compact(entry)}` -> `#{JsonText.compact(upstream)}`"
        end
      end

      # Deprecated methods whose remove_in version has shipped are deleted now.
      def expire_entries
        @state.entries.keys.sort.each do |name|
          entry = @state.entries[name]
          remove_in = entry.is_a?(Hash) ? entry["remove_in"] : nil
          next unless Sync.expired?(remove_in, @version)

          @state.entries.delete(name)
          since = entry["deprecated_since"] || "an earlier version"
          @report.deprecations_expired << "`#{name}`: deleted; deprecated since #{since} and kept through " \
                                          "version #{remove_in} (the SDK is at #{@version})"
          @report.breaking << "`#{name}` is deleted: it was deprecated since #{since} and kept through version " \
                              "#{remove_in}"
        end
      end

      # Compares the server method names before and after the sync.
      def classify_methods
        @old_names = server_names(@old_ops) { |key| old_naming(key) }
        @new_names = server_names(@new_ops) { |key| new_naming(key) }
        @old_names.each { |name, old_key| classify(name, old_key, @new_names[name]) }
        @new_names.each do |name, key|
          next if @old_names.key?(name)

          if !@old_ops.key?(key)
            @report.added << "`#{key}`: `#{name}`"
          elsif JsonText.ident(old_naming(key)).nil?
            @report.added << "`#{key}`: now a server operation, `#{name}`"
          end
        end
      end

      def server_names(ops)
        ops.keys.sort.each_with_object({}) do |key, out|
          name = JsonText.ident(yield(key))
          out[name] ||= key if name
        end
      end

      def classify(name, old_key, new_key)
        if new_key == old_key
          auth_change(name, old_key)
        elsif new_key && !@new_ops.key?(old_key)
          moved(name, old_key, new_key)
        elsif new_key
          reassigned(name, old_key, new_key)
        elsif !@new_ops.key?(old_key)
          removed(name, old_key)
        else
          naming_changed(name, old_key)
        end
      end

      def auth_change(name, key)
        before = old_naming(key)["auth"]
        after = new_naming(key)["auth"]
        return if before == after

        @report.naming << "`#{key}` (`#{name}`): auth changed from `#{before}` to `#{after}`"
        @report.breaking << "`#{name}` (`#{key}`): now authenticates with `#{after}` instead of `#{before}`"
      end

      def moved(name, old_key, new_key)
        before = @old_ops[old_key]
        after = @new_ops[new_key]
        notes = Details.new(before.doc, after.doc).operation(before, after)
        breaking = notes.select(&:last)
        head = "`#{name}`#{" **breaking**" unless breaking.empty?}: moved from `#{old_key}` to `#{new_key}`"
        @report.moved << (notes.empty? ? "#{head}; same parameters, request body and response" : nested(head, notes))
        breaking.map(&:first).each do |text|
          @report.breaking << "`#{name}` moved from `#{old_key}` to `#{new_key}`: #{text}"
        end
      end

      def reassigned(name, old_key, new_key)
        now = JsonText.ident(new_naming(old_key))
        rest = now ? "; `#{old_key}` is `#{now}` now" : ""
        @report.renamed << "`#{name}` **breaking**: now calls `#{new_key}` instead of `#{old_key}`#{rest}"
        @report.breaking << "`#{name}` now calls `#{new_key}` instead of `#{old_key}`, a different operation " \
                            "(no deprecated alias is possible: the name is taken)"
      end

      def removed(name, key)
        deprecate(name, key, "removed")
        @report.removed << "`#{key}` (`#{name}`): deprecated, kept through version #{@remove_in} " \
                           "(openapi/#{DEPRECATED_FILE})"
        @report.breaking << "`#{name}` (`#{key}`) was removed upstream; the method is deprecated and kept " \
                            "through version #{@remove_in}"
      end

      # The operation is still upstream, but its server naming changed.
      def naming_changed(name, key)
        after = new_naming(key)
        if after.nil?
          @report.removed << "`#{key}` (`#{name}`): lost its SDK naming; the generator fails until it is named " \
                             "again (see Action needed)"
          @report.breaking << "`#{name}` (`#{key}`) has no SDK naming any more"
        elsif after["server"] != true
          @report.removed << "`#{key}` (`#{name}`): no longer a server operation (auth `#{after["auth"]}`); the " \
                             "method is removed now, without a deprecation period"
          @report.breaking << "`#{name}` (`#{key}`) is removed: the operation now needs `#{after["auth"]}`, and " \
                              "server SDKs never expose such operations (docs/DESIGN.md section 4)"
        else
          renamed(name, key, JsonText.ident(after))
        end
      end

      def renamed(name, key, replacement)
        deprecate(name, key, "renamed", replacement)
        @report.renamed << "`#{key}`: `#{name}` renamed to `#{replacement}`; `#{name}` stays as a deprecated " \
                           "alias through version #{@remove_in}"
        @report.breaking << "`#{name}` was renamed upstream to `#{replacement}` (`#{key}`); the old name is " \
                            "deprecated and kept through version #{@remove_in}"
      end

      # Records +name+ in deprecated-operations.json with a frozen copy of the old operation.
      def deprecate(name, key, reason, replacement = nil)
        entry = {
          "reason" => reason, "operation_key" => key, "x-didit-sdk" => JsonText.normalize(old_naming(key)),
          "since" => @date, "deprecated_since" => @version, "remove_in" => @remove_in
        }
        entry["replacement"] = replacement if replacement
        entry["note"] = deprecation_note(entry)
        entry["operation"] = Freeze.operation(@old_ops[key])
        @state.entries[name] = entry
        @fresh << name
        @report.deprecations_added << if replacement
                                        "`#{name}`: deprecated alias of `#{replacement}` through version #{@remove_in}"
                                      else
                                        "`#{name}`: deprecated (`#{key}` was removed upstream on #{@date}), kept " \
                                          "through version #{@remove_in}"
                                      end
        follow_rename(name, replacement) if replacement
      end

      # Older aliases that pointed at +name+ now point at its replacement.
      def follow_rename(name, replacement)
        @state.entries.each do |other, entry|
          next if other == name || !entry.is_a?(Hash) || entry["replacement"] != name

          entry["replacement"] = replacement
          entry["note"] = deprecation_note(entry)
        end
      end

      def deprecation_note(entry)
        if entry["replacement"]
          "Renamed to #{entry["replacement"]} on #{entry["since"]}; this deprecated alias is kept through version " \
            "#{entry["remove_in"]}."
        else
          "Removed from the API contract on #{entry["since"]}; this deprecated method is kept through version " \
            "#{entry["remove_in"]}."
        end
      end

      # An entry whose name a live server operation provides again is not deprecated any more.
      def drop_returning_entries
        @state.entries.keys.sort.each do |name|
          key = @new_names[name]
          next if key.nil? || @fresh.include?(name)

          @state.entries.delete(name)
          @report.deprecations_dropped << "`#{name}`: provided again by `#{key}`; its deprecation entry was deleted"
        end
      end

      # "head" with one sub-bullet per note, breaking notes first, at most 20.
      def nested(head, notes, exposed: true)
        ordered = notes.partition(&:last).flatten(1)
        lines = ordered.first(20).map { |text, breaking| "  - #{text}#{" (breaking)" if breaking && exposed}" }
        lines << "  - ... and #{ordered.size - 20} more differences" if ordered.size > 20
        "#{head}\n#{lines.join("\n")}"
      end
    end
  end
end
