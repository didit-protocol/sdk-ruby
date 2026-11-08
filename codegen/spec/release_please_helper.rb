# frozen_string_literal: true

require "json"

# What release-please 17.6.0 (googleapis/release-please-action v5) makes of a spec sync, as
# far as the release notes and the version bump go, read from release-please-config.json.
module ReleasePlease
  CONFIG = File.expand_path("../../release-please-config.json", __dir__)
  # A blank line before a commit header of a standard type starts another commit.
  SPLIT = /\r?\n\r?\n(?=(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\(.*?\))?: )/

  module_function

  def config
    JSON.parse(File.read(CONFIG, encoding: "UTF-8")).fetch("packages").fetch(".")
  end

  # [type, breaking, description] of each commit release-please reads from one commit: the
  # pull request's BEGIN_COMMIT_OVERRIDE block replaces the message, and BEGIN_NESTED_COMMIT
  # blocks or a blank line before a standard type split it (preprocessCommitMessage and
  # splitMessages in src/commit.ts).
  def commits(message, pull_request_body = nil)
    split(override(message, pull_request_body)).filter_map do |raw|
      match = raw.strip.lines.first.to_s.chomp.match(/\A(\w+)(?:\(([^()]*)\))?(!)?: (.+)\z/)
      next if match.nil? # "could not be parsed", skipped

      [match[1], !match[3].nil? || raw.match?(/^BREAKING[ -]CHANGE: /), match[4]]
    end
  end

  def override(message, pull_request_body)
    block = pull_request_body.to_s.split("BEGIN_COMMIT_OVERRIDE", 2)[1]
    text = block.to_s.split("END_COMMIT_OVERRIDE", 2).first.to_s.strip
    text.empty? ? message : text
  end

  def split(message)
    parts = message.split("BEGIN_NESTED_COMMIT")
    main = parts.first.to_s
    nested = parts.drop(1).map do |part|
      inner, *rest = part.split("END_NESTED_COMMIT", -1)
      main += rest.join("END_NESTED_COMMIT")
      inner
    end
    main.split(SPLIT).reject(&:empty?) + nested
  end

  # [bump, {section => descriptions}]: hidden types leave the notes
  # (conventional-changelog-conventionalcommits), empty notes open no release pull request
  # (BaseStrategy.buildReleasePullRequest), breaking is major and feat is minor from 1.0.0 on
  # (DefaultVersioningStrategy).
  def release(commits)
    notes = notes(commits)
    return [nil, {}] if notes.empty?
    return ["major", notes] if commits.any? { |_, breaking, _| breaking }

    [commits.any? { |type, _, _| type == "feat" } ? "minor" : "patch", notes]
  end

  def notes(commits)
    sections = config.fetch("changelog-sections").to_h { |section| [section["type"], section] }
    commits.each_with_object({}) do |(type, breaking, description), out|
      (out["BREAKING CHANGES"] ||= []) << description if breaking
      entry = sections[type]
      (out[entry["section"]] ||= []) << description if entry && !entry["hidden"]
    end
  end

  # What .github/workflows/spec-sync.yml publishes as the pull request body.
  def published_body(report)
    "#{report.summary.lines.drop(2).join}\n## Checks\n\n- [x] `bundle exec rake spec`\n\n" \
      "Published by a spec sync run.\n\n#{report.release}"
  end

  # The commits release-please reads after a squash merge with the pull request title.
  def squash(report)
    commits(report.title, published_body(report))
  end
end
