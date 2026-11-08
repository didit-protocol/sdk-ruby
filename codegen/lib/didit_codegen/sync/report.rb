# frozen_string_literal: true

require "json"

module DiditCodegen
  module Sync
    # What one spec sync changed, rendered as the pull request summary, the "Release" section
    # that ends the pull request body and the commit message (docs/DESIGN.md sections 3.1 and 13).
    #
    # The type is feat (a minor release) when a caller can observe anything that changed, also
    # when it can break typed code, and chore (no release on its own) when only documentation
    # changed. Never "!" and never a BREAKING CHANGE footer: each breaking change becomes one
    # api(spec) line, which release-please-config.json lists under API_CHANGES_SECTION.
    class Report
      MAX_ITEMS = 100
      # GitHub refuses a pull request body or comment over 65,536 characters. The body is the
      # summary, the checks (about 1,000 characters) and the release section.
      MAX_SUMMARY = 40_000
      MAX_RELEASE = 22_000
      API_CHANGE_TYPE = "api"
      API_CHANGES_SECTION = "API changes that can break typed code"
      BREAKING_INTRO = "These changes mirror the API and can break typed code. They ship in a minor version " \
                       "(docs/DESIGN.md section 13), and the release notes list them under " \
                       "\"#{API_CHANGES_SECTION}\".".freeze
      # The first line of the "Release" section, by type.
      RELEASES = {
        "feat" => "`feat(spec)`: callers can observe what changed, so this releases a minor version.",
        "chore" => "`chore(spec)`: only documentation changed, so this releases nothing on its own; it ships " \
                   "with the next release."
      }.freeze
      RELEASE_NOTE = "Release Please reads the block below instead of the commits, so the type and the lines " \
                     "survive a squash merge with the title; keep it when you edit this description. Merge with " \
                     "\"Squash and merge\": after a merge commit the release notes repeat each line for the merge " \
                     "commit and for every commit of this pull request."
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
      # True once the sync changed something a caller can observe: an operation, parameter,
      # field, enum value, response shape or SDK method, more than its documentation.
      attr_accessor :observable

      # Nested commits for release-please: it splits a message into several commits at these
      # blocks, also for a type outside its standard list such as API_CHANGE_TYPE.
      def self.nested(lines)
        lines.map { |line| "BEGIN_NESTED_COMMIT\n#{line}\nEND_NESTED_COMMIT" }.join("\n")
      end

      def initialize(date)
        @date = date
        @files = []
        LISTS.each { |list| instance_variable_set(:"@#{list}", []) }
        @action_needed = nil
        @generated = nil
        @observable = false
      end

      # One row of the file table; +new_sha+ equals +old_sha+ when the file did not change.
      def add_file(file, url, old_sha, new_sha)
        @files << [file, url, old_sha, new_sha]
      end

      def breaking?
        !@breaking.empty?
      end

      # "feat" or "chore" (docs/DESIGN.md section 3.1).
      def type
        observable || breaking? ? "feat" : "chore"
      end

      def title
        "#{type}(spec): sync API spec #{date}"
      end

      # The commits release-please reads for this sync: the sync itself, then one api(spec)
      # line per breaking change, at most MAX_RELEASE characters.
      def release_lines
        [title, *capped_release(@breaking.uniq.map { |item| "#{API_CHANGE_TYPE}(spec): #{item}" })]
      end

      # The "Release" section that ends the pull request body: how this sync releases and the
      # override block release-please reads instead of the commits of the pull request.
      def release
        head, *rest = release_lines
        block = rest.empty? ? head : "#{head}\n\n#{Report.nested(rest)}"
        ["## Release", "", RELEASES.fetch(type), RELEASE_NOTE, "", "BEGIN_COMMIT_OVERRIDE", block,
         "END_COMMIT_OVERRIDE", ""].join("\n")
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

        out << "\n#{Report.nested(release_lines.drop(1))}\n"
      end

      private

      def changed_files
        @files.reject { |_, _, old_sha, new_sha| old_sha == new_sha }.map(&:first)
      end

      def body
        out = breaking_section
        out.concat(action_section) if action_needed
        out.push("## Upstream documents", "", intro, "", table, "")
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

      def breaking_section
        return section("Breaking changes", @breaking, empty: "None detected.") unless breaking?

        ["## Breaking changes", "", BREAKING_INTRO, "", *capped(@breaking.uniq), ""]
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

      # +lines+ up to MAX_RELEASE characters (with their nested-commit markers and the text of
      # the release section), then one line that counts the rest.
      def capped_release(lines)
        budget = MAX_RELEASE - 1_000
        kept = []
        lines.each do |line|
          break if (budget -= line.length + 40).negative?

          kept << line
        end
        rest = lines.size - kept.size
        kept << "#{API_CHANGE_TYPE}(spec): #{rest} more changes, listed in the spec sync pull request" if rest.positive?
        kept
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
