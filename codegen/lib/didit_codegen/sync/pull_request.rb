# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"

module DiditCodegen
  module Sync
    # The open spec sync pull request when a sync is pushed on top of commits from people
    # (docs/DESIGN.md section 3.1). Its description keeps listing the operations and schemas
    # of the first sync; "Breaking changes" and the release block gain this sync's entries,
    # and feat wins over chore in the title and the "Release" section, so the description and
    # release-please cover every sync on the branch. This sync's own summary goes into a
    # comment, which "Later syncs" points to.
    #
    #   ruby codegen/sync_pull_request.rb --previous PR.json --body BODY.md --out DIR
    #
    # PR.json is what `gh pr view --json title,body` prints; BODY.md is the description this
    # sync would have on its own (the summary without its title, the checks and the Release
    # section). Writes DIR/title.txt, DIR/body.md and DIR/comment.md.
    module PullRequest
      USAGE = "usage: ruby codegen/sync_pull_request.rb --previous PR.json --body BODY.md --out DIR"
      OVERRIDE = /^BEGIN_COMMIT_OVERRIDE\n(.*?)\nEND_COMMIT_OVERRIDE$/m
      NESTED = /BEGIN_NESTED_COMMIT\n(.*?)\nEND_NESTED_COMMIT/m
      SYNC_HEADER = /\A(?<type>[a-z]+)\(spec\): sync API spec (?<date>\d{4}-\d{2}-\d{2})\z/
      BREAKING_SECTION = /^## Breaking changes\n.*?(?=^## |^BEGIN_COMMIT_OVERRIDE$|\z)/m
      LATER_SECTION = /^## Later syncs\n.*?(?=^## |^BEGIN_COMMIT_OVERRIDE$|\z)/m
      RELEASE_HEADING = /^## Release$/
      INCOMPLETE = "The description had no such list before the sync of "
      CONTINUED = "Release Please reads the block below instead of the commits; later syncs on top of this branch " \
                  "add their lines to it. Keep it when you edit this description, and merge with \"Squash and merge\"."

      Result = Struct.new(:title, :body, :comment)

      module_function

      # @return [Integer] the exit code
      def main(argv, err: $stderr)
        options = parse(argv)
        previous = JSON.parse(File.read(options.fetch(:previous), encoding: "UTF-8"))
        raise InputError, "#{options[:previous]} is not a JSON object." unless previous.is_a?(Hash)

        result = continue(previous["title"].to_s, previous["body"].to_s,
                          File.read(options.fetch(:body), encoding: "UTF-8"))
        out = options.fetch(:out)
        FileUtils.mkdir_p(out)
        { "title.txt" => "#{result.title}\n", "body.md" => result.body, "comment.md" => result.comment }
          .each { |name, text| File.write(File.join(out, name), text, mode: "wb") }
        0
      rescue OptionParser::ParseError, KeyError => e
        err.puts("sync-pull-request: #{e.message}\n#{USAGE}")
        1
      rescue InputError, JSON::ParserError, SystemCallError => e
        err.puts("sync-pull-request: #{e.message}")
        1
      end

      def parse(argv)
        options = {}
        rest = OptionParser.new do |o|
          o.banner = USAGE
          o.on("--previous FILE", "the pull request, as `gh pr view --json title,body` prints it") do |v|
            options[:previous] = v
          end
          o.on("--body FILE", "the description this sync would have on its own") { |v| options[:body] = v }
          o.on("--out DIR", "where to write title.txt, body.md and comment.md") { |v| options[:out] = v }
        end.parse(argv)
        raise OptionParser::InvalidArgument, "unexpected arguments: #{rest.join(" ")}" unless rest.empty?

        missing = %i[previous body out].reject { |key| options.key?(key) }
        raise OptionParser::MissingArgument, missing.map { |key| "--#{key}" }.join(", ") unless missing.empty?

        options
      end

      # The title, description and comment for this sync's +body+ pushed on top of the open
      # pull request +previous_title+ / +previous_body+.
      #
      # @raise [InputError] when +body+ has no release block of a spec sync
      def continue(previous_title, previous_body, body)
        previous_body = previous_body.gsub("\r\n", "\n")
        this, lines = own_release(body)
        previous = OVERRIDE.match(previous_body)
        type = merged_type(this[:type], previous, previous_title)
        title = "#{type}(spec): sync API spec #{this[:date]}"
        text = with_block(previous_body, previous, title, lines, type)
        Report::RELEASES.each_value { |release| text = text.gsub(release) { Report::RELEASES.fetch(type) } }
        text = breaking_so_far(text, body, this[:date])
        text = later_sync(text, "- #{this[:date]} (`#{this[:type]}(spec)`): its operation and schema changes are " \
                                "in the comment it added.")
        Result.new(title, text, comment(body, previous.nil?))
      end

      # The first line of this sync's release block, parsed, and its nested lines.
      def own_release(body)
        found = OVERRIDE.match(body)
        raise InputError, "the pull request text has no release block." if found.nil?

        head, rest = found[1].split("\n", 2)
        this = SYNC_HEADER.match(head.to_s)
        raise InputError, "unexpected first line of the release block: #{head.inspect}" if this.nil?

        [this, nested(rest.to_s)]
      end

      # feat once any sync on the branch needs it. Without a release block nobody recorded
      # what the earlier syncs changed, so they count as feat.
      def merged_type(this_type, previous, previous_title)
        return "feat" if previous.nil? || this_type == "feat"

        earlier = SYNC_HEADER.match(previous[1].split("\n", 2).first.to_s) || SYNC_HEADER.match(previous_title.strip)
        earlier ? earlier[:type] : this_type
      end

      # +previous_body+ with its release block replaced by one that also holds +lines+, or
      # with a Release section added when it has no block.
      def with_block(previous_body, previous, title, lines, type)
        if previous.nil?
          return "#{previous_body.rstrip}\n\n## Release\n\n#{Report::RELEASES.fetch(type)}\n#{CONTINUED}\n\n" \
                 "#{block(title, "", lines)}\n"
        end

        old_head, old_rest = previous[1].split("\n", 2)
        first, kept = if SYNC_HEADER.match?(old_head.to_s)
                        [title, old_rest.to_s]
                      else
                        # A first line someone wrote stays; the sync becomes a nested commit.
                        [old_head, "#{old_rest}\n#{Report.nested([title])}"]
                      end
        previous_body[0...previous.begin(0)] + block(first, kept, lines) + previous_body[previous.end(0)..]
      end

      def block(first, kept, lines)
        kept = kept.strip
        added = lines - nested(kept)
        rest = [kept, Report.nested(added)].reject(&:empty?).join("\n")
        "BEGIN_COMMIT_OVERRIDE\n#{first}#{"\n\n#{rest}" unless rest.empty?}\nEND_COMMIT_OVERRIDE"
      end

      def nested(text)
        text.scan(NESTED).map { |(line)| line.strip }
      end

      # "Breaking changes" of +text+ with those of this sync's +body+ added.
      def breaking_so_far(text, body, date)
        earlier = BREAKING_SECTION.match(text)
        items = (bullets(earlier) + bullets(BREAKING_SECTION.match(body))).uniq
        note = if earlier.nil?
                 "#{INCOMPLETE}#{date}: changes of earlier syncs on this branch are missing."
               else
                 earlier[0].lines(chomp: true).find { |line| line.start_with?(INCOMPLETE) }.to_s
               end
        lines = ["## Breaking changes", ""]
        lines.concat(items.empty? ? ["None detected."] : [Report::BREAKING_INTRO, "", *items.map { |i| "- #{i}" }])
        lines.push("", note) unless note.empty?
        section = "#{lines.join("\n")}\n\n"
        earlier ? text[0...earlier.begin(0)] + section + text[earlier.end(0)..] : section + text
      end

      def bullets(found)
        return [] if found.nil?

        found[0].lines(chomp: true).select { |line| line.start_with?("- ") }.map { |line| line[2..] }
      end

      # +line+ added to "Later syncs", a section placed before "Release".
      def later_sync(text, line)
        found = LATER_SECTION.match(text)
        if found
          return "#{text[0...found.begin(0)]}#{found[0].rstrip}\n#{line}\n\n#{text[found.end(0)..]}"
        end

        stop = OVERRIDE.match(text)&.begin(0) || text.length
        at = text.rindex(RELEASE_HEADING, stop) || stop
        "#{text[0...at]}## Later syncs\n\n#{line}\n\n#{text[at..]}"
      end

      # This sync's summary and checks, without its Release section.
      def comment(body, without_block)
        note = "The breaking changes and release lines of this sync were added to the description."
        if without_block
          note += " The description had no release block, so the earlier syncs on this branch count as " \
                  "`feat(spec)`; change its first line to `chore(spec)` when they only changed documentation."
        end
        summary = body.split(RELEASE_HEADING, 2).first.to_s.rstrip
        "#{summary}\n\n#{note}\n"
      end
    end
  end
end
