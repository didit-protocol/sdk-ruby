# frozen_string_literal: true

require "date"
require "optparse"

module DiditCodegen
  module Sync
    # ruby codegen/spec_sync.rb [--from-dir DIR] [--summary FILE] [--commit-message FILE] [--date YYYY-MM-DD]
    #
    # Exit codes: 0 synced (or no upstream change), 1 a download or input problem (nothing
    # written), 2 the synced documents were written but the generator failed (the summary
    # says what to fix under "Action needed").
    class CLI
      USAGE = "usage: ruby codegen/spec_sync.rb [--from-dir DIR] [--summary FILE] [--commit-message FILE] " \
              "[--date YYYY-MM-DD]"

      def initialize(root:, env: ENV, out: $stdout, err: $stderr, now: -> { Time.now.utc },
                     downloader: Downloader.new)
        @root = root
        @env = env
        @out = out
        @err = err
        @now = now
        @downloader = downloader
      end

      # @return [Integer] the exit code
      def run(argv)
        options = parse(argv)
        return 0 if options[:help]

        now = @now.call
        date = options[:date] || now.getutc.strftime("%Y-%m-%d")
        result = Sync.run(options[:root] || @root, downloads(options[:from_dir]), date: date, now: now)
        result.changed ? report(result, options, date) : unchanged(options, date)
      rescue OptionParser::ParseError => e
        @err.puts("spec-sync: #{e.message}\n#{USAGE}")
        1
      rescue InputError => e
        @err.puts("spec-sync: #{e.message}\nNothing was written.")
        1
      end

      private

      def parse(argv)
        options = {}
        parser = OptionParser.new do |o|
          o.banner = USAGE
          o.on("--from-dir DIR", "read verification.json and account.json from DIR instead of downloading") do |v|
            options[:from_dir] = v
          end
          o.on("--summary FILE", "write the pull request title and body (Markdown) to FILE") do |v|
            options[:summary] = v
          end
          o.on("--commit-message FILE", "write the commit message to FILE") { |v| options[:commit_message] = v }
          o.on("--date YYYY-MM-DD", "the sync date (default: today, UTC)") { |v| options[:date] = check_date(v) }
          o.on("--root DIR", "the repository to sync (default: the one containing this script)") do |v|
            options[:root] = File.expand_path(v)
          end
          o.on("-h", "--help", "show this help") do
            @out.puts(o.help)
            options[:help] = true
          end
        end
        rest = parser.parse(argv)
        raise OptionParser::InvalidArgument, "unexpected arguments: #{rest.join(" ")}" unless rest.empty?

        options
      end

      def check_date(value)
        Date.strptime(value, "%Y-%m-%d")
        raise OptionParser::InvalidArgument, "--date #{value}" unless value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        value
      rescue Date::Error
        raise OptionParser::InvalidArgument, "--date #{value}"
      end

      def downloads(dir)
        UPSTREAM.to_h do |file, url|
          next [file, @downloader.fetch(url)] if dir.nil?

          path = [file, UPSTREAM_NAMES.fetch(file)].map { |name| File.join(dir, name) }.find { |p| File.file?(p) }
          raise InputError, "#{File.join(dir, file)} is missing." unless path

          [file, File.binread(path)]
        end
      end

      def unchanged(options, date)
        @out.puts("No upstream change")
        write_file(options[:summary], "No upstream change\n")
        github_output(changed: false, breaking: false, date: date)
        0
      end

      def report(result, options, date)
        report = result.report
        write_file(options[:summary], report.summary)
        write_file(options[:commit_message], report.commit_message)
        github_output(changed: true, breaking: report.breaking?, date: date)
        # The log keeps the whole summary, also when the pull request body is truncated.
        @out.puts(report.summary(limit: false))
        return 0 unless result.generator_error

        @err.puts("spec-sync: the synced documents were written, but the generator failed:\n" \
                  "#{result.generator_error.message}")
        2
      end

      def write_file(path, text)
        File.write(path, text, mode: "wb") if path
      end

      def github_output(changed:, breaking:, date:)
        path = @env["GITHUB_OUTPUT"]
        return if path.nil? || path.empty?

        File.open(path, "a", encoding: "UTF-8") do |f|
          f.puts("changed=#{changed}")
          f.puts("breaking=#{breaking}")
          f.puts("date=#{date}")
        end
      end
    end
  end
end
