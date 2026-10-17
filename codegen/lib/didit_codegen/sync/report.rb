# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # What one spec sync changed, rendered as the pull request summary and the commit message.
    class Report
      MAX_ITEMS = 100
      MAX_SUMMARY = 60_000
      MAX_FOOTER_ITEMS = 20
      LISTS = %i[
        breaking added removed renamed moved changed schemas naming deprecations_added deprecations_expired
        deprecations_dropped
      ].freeze
      OPERATION_LISTS = [
        [:added, "Added", nil],
        [:removed, "Removed",
         "Server methods of removed operations stay for one minor version as deprecated methods " \
         "(docs/DESIGN.md section 3.1)."],
        [:renamed, "Renamed", "The old name stays for one minor version as a deprecated alias."],
        [:moved, "Moved", "The method keeps its name and calls the new path."],
        [:changed, "Changed", nil]
      ].freeze
      DEPRECATION_LISTS = [
        [:deprecations_added, "Added"], [:deprecations_expired, "Expired"],
        [:deprecations_dropped, "No longer deprecated"]
      ].freeze

      attr_reader :date, :files, *LISTS
      # [message, {operation key => suggested overlay entry}] when the generator failed.
      attr_accessor :action_needed, :generated

      def initialize(date)
        @date = date
        @files = []
        LISTS.each { |list| instance_variable_set(:"@#{list}", []) }
        @action_needed = nil
        @generated = nil
      end

      # One row of the file table; +new_sha+ equals +old_sha+ when the file did not change.
      def add_file(file, url, old_sha, new_sha)
        @files << [file, url, old_sha, new_sha]
      end

      def breaking?
        !@breaking.empty?
      end

      def title
        "chore(spec): sync API spec #{date}"
      end

      # The pull request title, a blank line and the body, at most MAX_SUMMARY characters
      # unless +limit+ is false.
      def summary(limit: true)
        text = "#{title}\n\n#{body}"
        return text if !limit || text.length <= MAX_SUMMARY

        truncate(text)
      end

      def commit_message
        counts = OPERATION_LISTS.map { |list, label, _| "#{send(list).size} #{label.downcase}" }.join(", ")
        out = "#{title}\n\n"
        out << "Synced #{changed_files.map { |f| "openapi/#{f}" }.join(" and ")} from the published API contract " \
               "(docs/DESIGN.md section 3.1).\nOperations: #{counts}.\n"
        out << if action_needed
                 "The generator failed, so the generated code is not updated; see Action needed in the pull request.\n"
               else
                 "Regenerated the SDK.\n"
               end
        return out unless breaking?

        out << "\nBREAKING CHANGE: the API spec sync changes the SDK surface.\n"
        out << capped(@breaking, MAX_FOOTER_ITEMS).join("\n")
        out << "\n"
      end

      private

      def changed_files
        @files.reject { |_, _, old_sha, new_sha| old_sha == new_sha }.map(&:first)
      end

      def body
        out = [intro, "", table, ""]
        out.concat(action_section) if action_needed
        out.concat(section("Breaking changes", @breaking, empty: "None detected."))
        out.concat(operations_section)
        out.concat(section("Schemas", @schemas, empty: "No component schema changed."))
        out.concat(section("SDK naming", @naming, empty: "No overlay entry changed."))
        out.concat(deprecations_section)
        "#{out.join("\n").rstrip}\n"
      end

      def intro
        generated = if action_needed
                      "The generator failed, so the generated code was not updated (see Action needed)."
                    else
                      "Regenerated the SDK: #{@generated || 0} generated files changed."
                    end
        "Automated sync of the upstream OpenAPI documents (docs/DESIGN.md section 3.1) by " \
          "`codegen/spec_sync.rb`. #{generated} Generated code under `lib/`, `sig/` and `spec/generated/` " \
          "comes from `codegen/` and `openapi/`; never edit it by hand."
      end

      def table
        rows = @files.map do |file, url, old_sha, new_sha|
          "| `openapi/#{file}` | #{url} | `#{old_sha}` | #{old_sha == new_sha ? "unchanged" : "`#{new_sha}`"} |"
        end
        ["| File | URL | Old SHA-256 | New SHA-256 |", "|---|---|---|---|", *rows].join("\n")
      end

      def action_section
        message, suggestions = action_needed
        out = ["## Action needed", "",
               "The generator failed on the synced documents. Fix it on this branch (usually an entry in " \
               "`openapi/overlay.json`, or `x-didit-sdk` upstream; docs/DESIGN.md section 4), run " \
               "`bundle exec rake generate` and push the result:",
               "", "```text", message.to_s.strip, "```", ""]
        return out if suggestions.nil? || suggestions.empty?

        listed = suggestions.first(MAX_ITEMS).to_h
        out << "Suggested `openapi/overlay.json` entries for the operations without SDK naming (check " \
               "`resource`, `method`, `auth` and `server` before committing; `server` is false for end-user " \
               "or device token operations):"
        out.push("", "```json", JSON.pretty_generate(listed, indent: " "), "```")
        out << "" << "... and #{suggestions.size - MAX_ITEMS} more operations." if suggestions.size > MAX_ITEMS
        out << ""
      end

      def section(heading, items, empty:)
        ["## #{heading}", "", *(items.empty? ? [empty] : capped(items)), ""]
      end

      def operations_section
        out = ["## Operations", ""]
        OPERATION_LISTS.each do |list, label, explanation|
          items = send(list)
          next if items.empty?

          out.push("### #{label} (#{items.size})", "")
          out.push(explanation, "") if explanation
          out.concat(capped(items)) << ""
        end
        out << "No operation was added, removed or changed." << "" if out.size == 2
        out
      end

      def deprecations_section
        out = ["## Deprecations", ""]
        DEPRECATION_LISTS.each do |list, label|
          items = send(list)
          next if items.empty?

          out.push("### #{label} (#{items.size})", "")
          out.concat(capped(items)) << ""
        end
        out << "No deprecation was added or expired." << "" if out.size == 2
        out
      end

      def capped(items, max = MAX_ITEMS)
        out = items.first(max).map { |item| "- #{item}" }
        out << "- ... and #{items.size - max} more (see the workflow log for the full summary)" if items.size > max
        out
      end

      def truncate(text)
        note = "\n_The summary was truncated at #{MAX_SUMMARY} characters; the spec sync workflow log has all of it._\n"
        cut = text[0, MAX_SUMMARY - note.length - 8]
        cut = cut[0, cut.rindex("\n") || cut.length]
        cut += "\n```" if cut.scan(/^```/).size.odd?
        "#{cut}\n#{note}"
      end
    end
  end
end
