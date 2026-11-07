# frozen_string_literal: true

require "didit_codegen/sync"
require "digest"
require "stringio"

# How a spec sync releases (docs/DESIGN.md sections 3.1 and 13): the type and the breaking
# changes of two real upstream changes, the release-please configuration, and the release
# block of a sync pushed on top of commits from people.
RSpec.describe "Spec sync releases" do
  report_class = DiditCodegen::Sync::Report
  fixtures = File.expand_path("fixtures/spec-sync", __dir__)
  repo_root = File.expand_path("../..", __dir__)
  # openapi/verification.json at these didit-protocol/sdk-python commits, and the start of its SHA-256.
  pinned = {
    "2026-11-04/before.json" => %w[9fe57fc69299601e59cc7a64c1db370fea5c7461 12b2fdb05572755d],
    "2026-11-04/after.json" => %w[e002a815773bbd1599256e2774046ee76520c6c8 d1783bd862848198],
    "2026-11-06/before.json" => %w[fe9f57a1dfb6374bfd391750d2044fc7a206e4ea 9f8cdf8be8157588],
    "2026-11-06/after.json" => %w[ccc799410f82eee1c25c7ce5abc6caa53846be6b 1b0c7bdd8d7957bd]
  }
  decision = "GET /v3/session/{sessionId}/decision/"
  import_shared = "POST /v3/session/import-shared/"
  # The API change of 2026-11-04 as every server SDK reports it: [operation, field, kind].
  breaking_2026_11_04 = [
    [decision, "registry_checks[].company.registry_data", "now-null"],
    [decision, "registry_checks[].ownership_structure", "now-null"],
    [decision, "signatures[].confirmation.channel", "now-null"],
    ["POST /v3/email/risk/", "email.email_intelligence.reason_codes[]", "string->object"],
    ["POST /v3/email/risk/", "email.enrichment.reason_codes[]", "string->object"],
    ["POST /v3/kyb/select/", "kyb_registry.registry_data", "now-null"],
    ["POST /v3/kyb/shareholders/", "kyb_registry.registry_data", "now-null"],
    ["POST /v3/kyb/ubo/", "kyb_registry.registry_data", "now-null"],
    ["POST /v3/phone/risk/", "phone.enrichment.reason_codes[]", "string->object"],
    ["POST /v3/phone/risk/", "phone.phone_intelligence.reason_codes[]", "string->object"],
    [import_shared, "registry_checks[].company.registry_data", "now-null"],
    [import_shared, "registry_checks[].ownership_structure", "now-null"],
    [import_shared, "signatures[].confirmation.channel", "now-null"],
    ["POST /v3/session/{sessionId}/signatures/{nodeId}/validate/", "signatures[].confirmation.channel", "now-null"]
  ]

  # release-please 17.6.0 (googleapis/release-please-action v5) -------------------------------

  define_method(:config) do
    JSON.parse(File.read(File.join(repo_root, "release-please-config.json"), encoding: "UTF-8"))
        .fetch("packages").fetch(".")
  end

  # [type, breaking, description] of each commit release-please reads from one commit: the
  # pull request's BEGIN_COMMIT_OVERRIDE block replaces the message, and BEGIN_NESTED_COMMIT
  # blocks or a blank line before a standard type split it (preprocessCommitMessage and
  # splitMessages in src/commit.ts).
  def release_commits(message, pull_request_body = nil)
    if pull_request_body
      override = pull_request_body.split("BEGIN_COMMIT_OVERRIDE", 2)[1]
      text = override.to_s.split("END_COMMIT_OVERRIDE", 2).first.to_s.strip
      message = text unless text.empty?
    end
    parts = message.split("BEGIN_NESTED_COMMIT")
    messages = [parts.first.to_s]
    parts.drop(1).each do |part|
      nested, *rest = part.split("END_NESTED_COMMIT", -1)
      messages << nested
      messages[0] += rest.join("END_NESTED_COMMIT")
    end
    standard = "(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
    split = messages.first.split(/\r?\n\r?\n(?=#{standard}(?:\(.*?\))?: )/).reject(&:empty?) + messages.drop(1)
    split.filter_map do |raw|
      match = raw.strip.lines.first.to_s.chomp.match(/\A(\w+)(?:\(([^()]*)\))?(!)?: (.+)\z/)
      next if match.nil? # "could not be parsed", skipped

      [match[1], !match[3].nil? || raw.match?(/^BREAKING[ -]CHANGE: /), match[4]]
    end
  end

  # The version bump and the release notes sections: hidden types leave the notes
  # (conventional-changelog-conventionalcommits), empty notes open no release pull request
  # (BaseStrategy.buildReleasePullRequest), breaking is major and feat is minor from 1.0.0 on
  # (DefaultVersioningStrategy).
  def release(commits)
    sections = config.fetch("changelog-sections").to_h { |section| [section["type"], section] }
    notes = {}
    commits.each do |type, breaking, description|
      (notes["BREAKING CHANGES"] ||= []) << description if breaking
      entry = sections[type]
      (notes[entry["section"]] ||= []) << description if entry && !entry["hidden"]
    end
    return [nil, {}] if notes.empty?

    bump = if commits.any? { |_, breaking, _| breaking } then "major"
           elsif commits.any? { |type, _, _| type == "feat" } then "minor"
           else "patch"
           end
    [bump, notes]
  end

  # What .github/workflows/spec-sync.yml publishes as the pull request body.
  def published_body(report)
    "#{report.summary.lines.drop(2).join}\n## Checks\n\n- [x] `bundle exec rake spec`\n\n" \
      "Published by a spec sync run.\n\n#{report.release}"
  end

  # The commits release-please reads after a squash merge with the pull request title.
  def squash(report)
    release_commits(report.title, published_body(report))
  end

  describe "the pinned upstream changes" do
    define_method(:sync_pair) do |pair|
      Dir.mktmpdir("didit-release") do |root|
        # The other two documents stay as they are.
        account = document({ "/organizations/me/" => { "get" => { "responses" => { "200" => { "description" => "ok" } } } } })
        write_repo(root, verification: document({}), account: account)
        FileUtils.cp(File.join(fixtures, pair, "before.json"), File.join(root, "openapi", "verification.json"))
        downloads = %w[account.json authentication.json].to_h { |f| [f, File.binread(File.join(root, "openapi", f))] }
        downloads["verification.json"] = File.binread(File.join(fixtures, pair, "after.json"))
        # The classification only; the generator's own tests cover the generated code.
        allow(DiditCodegen::Generator).to receive(:new).and_return(instance_double(DiditCodegen::Generator, write: []))
        DiditCodegen::Sync.run(root, downloads, date: pair, now: Time.utc(2026, 11, 7, 6, 0, 0)).report
      end
    end

    # [operation, field, kind] of a breaking change of a changed operation's response.
    def triple(text)
      found = text.match(/\A`[^`]+` \(`(?<key>[^`]+)`\): response [\d, ]+ `(?<field>[^`]+)`: (?<what>.+)\z/)
      raise "unexpected breaking change: #{text}" if found.nil?

      types = found[:what].match(/\Atype changed from (\S+) to (\S+)\z/)
      kind = if found[:what] == "can now be null" then "now-null"
             elsif types then "#{types[1]}->#{types[2]}"
             else found[:what]
             end
      [found[:key], found[:field], kind]
    end

    it "are the pinned copies" do
      pinned.each do |name, (_commit, prefix)|
        expect(Digest::SHA256.file(File.join(fixtures, name)).hexdigest).to start_with(prefix), name
      end
    end

    it "release the API change of 2026-11-04 as a minor version that lists its 14 breaking changes" do
      report = sync_pair("2026-11-04")
      expect(report.title).to eq("feat(spec): sync API spec 2026-11-04")
      expect(report.breaking.map { |text| triple(text) }.sort).to eq(breaking_2026_11_04.sort)
      expect(report.breaking.size).to eq(14)

      summary = report.summary
      listed = summary[/^## Breaking changes\n(.*?)^## /m, 1].lines(chomp: true).grep(/\A- /)
      expect(listed).to eq(report.breaking.map { |text| "- #{text}" })
      expect(listed).to include(
        "- `email.assess_risk` (`POST /v3/email/risk/`): response 200 `email.enrichment.reason_codes[]`: type " \
        "changed from string to object",
        "- `kyb.list_shareholders` (`POST /v3/kyb/shareholders/`): response 200, 202 `kyb_registry.registry_data`: " \
        "can now be null"
      )
      bump, notes = release(squash(report))
      expect(bump).to eq("minor")
      expect(notes.fetch("Features")).to eq(["sync API spec 2026-11-04"])
      expect(notes.fetch(report_class::API_CHANGES_SECTION)).to eq(report.breaking)
      expect(notes).not_to have_key("BREAKING CHANGES")
      expect(published_body(report) + report.commit_message).not_to include("BREAKING CHANGE")
      expect(release(release_commits(report.commit_message))).to eq([bump, notes])
    end

    it "release nothing for the documentation-only change of 2026-11-06" do
      report = sync_pair("2026-11-06")
      expect(report.title).to eq("chore(spec): sync API spec 2026-11-06")
      expect(report.breaking).to eq([])
      expect(report.summary).to include("## Breaking changes\n\nNone detected.\n",
                                        "- `POST /v3/poa/` (`proof_of_address.verify`): documentation only\n")
      expect(squash(report)).to eq([["chore", false, "sync API spec 2026-11-06"]])
      expect(release(squash(report))).to eq([nil, {}])
    end
  end

  describe "release-please-config.json" do
    it "lists the api type first, as API changes that can break typed code, and hides chore" do
      sections = config.fetch("changelog-sections")
      expect(sections.first).to eq("type" => "api", "section" => report_class::API_CHANGES_SECTION)
      by_type = sections.to_h { |section| [section["type"], section] }
      expect(by_type.size).to eq(sections.size)
      expect(by_type.fetch("feat")).to eq("type" => "feat", "section" => "Features")
      expect(by_type.fetch("fix")).not_to have_key("hidden")
      %w[chore docs style refactor test build ci].each { |type| expect(by_type.fetch(type)["hidden"]).to be(true) }
      expect(sections.map(&:keys).flatten.uniq.sort).to eq(%w[hidden section type])
    end

    it "releases nothing for chore, ci and docs, a patch for fix, and reads the override block first" do
      expect(release(release_commits("chore(spec): sync API spec 2026-11-06"))).to eq([nil, {}])
      expect(release(release_commits("chore(deps): bump webmock"))).to eq([nil, {}])
      expect(release(release_commits("ci: spec sync releases API changes as minor versions"))).to eq([nil, {}])
      expect(release(release_commits("docs: README versioning"))).to eq([nil, {}])
      expect(release(release_commits("fix: retry on 503"))).to eq(["patch", { "Bug Fixes" => ["retry on 503"] }])
      merge = "Merge pull request #31 from didit-protocol/chore/spec-sync\n\nfeat(spec): sync API spec 2026-11-07"
      expect(release(release_commits(merge)).first).to eq("minor")
      report = report_class.new("2026-11-07")
      report.observable = true
      expect(release(release_commits("chore(spec): sync API spec 2026-11-07", published_body(report))).first)
        .to eq("minor")
    end
  end

  describe DiditCodegen::Sync::PullRequest do
    def own_body(date, observable: false, breaking: [])
      report = DiditCodegen::Sync::Report.new(date)
      report.observable = observable
      breaking.each do |field|
        report.breaking << "`x.#{field}` (`POST /v3/#{field}/`): response 200 `#{field}`: can now be null"
      end
      published_body(report)
    end

    def breaking_items(body)
      body[/^## Breaking changes\n(.*?)(?=^## )/m, 1].lines(chomp: true).grep(/\A- /)
    end

    let(:feat) { report_class::RELEASES.fetch("feat") }
    let(:chore) { report_class::RELEASES.fetch("chore") }

    it "adds the breaking changes and release lines of later syncs, and feat wins" do
      previous = "Hand-written intro.\n\n#{own_body("2026-11-05")}"
      first = described_class.continue("chore(spec): sync API spec 2026-11-05", previous,
                                       own_body("2026-11-06", breaking: %w[a]))
      expect(first.title).to eq("feat(spec): sync API spec 2026-11-06")
      expect(first.body).to start_with("Hand-written intro.\n")
      expect(first.body).to end_with(
        "BEGIN_COMMIT_OVERRIDE\nfeat(spec): sync API spec 2026-11-06\n\nBEGIN_NESTED_COMMIT\n" \
        "api(spec): `x.a` (`POST /v3/a/`): response 200 `a`: can now be null\nEND_NESTED_COMMIT\nEND_COMMIT_OVERRIDE\n"
      )
      expect(first.comment).not_to include("END_COMMIT_OVERRIDE", "## Release")
      expect(first.comment).to include("- `x.a` (`POST /v3/a/`): response 200 `a`: can now be null", "## Checks")
      expect(release(release_commits(first.title, first.body)).first).to eq("minor")

      # A later documentation-only sync keeps feat and the earlier lines, once each.
      second = described_class.continue(first.title, first.body, own_body("2026-11-07", breaking: %w[a b]))
      third = described_class.continue(second.title, second.body, own_body("2026-11-08"))
      expect(third.title).to eq("feat(spec): sync API spec 2026-11-08")
      expect(third.body.scan("api(spec): `x.a`").size).to eq(1)
      expect(third.body.scan("api(spec): `x.b`").size).to eq(1)
      expect(breaking_items(third.body)).to eq(
        ["- `x.a` (`POST /v3/a/`): response 200 `a`: can now be null",
         "- `x.b` (`POST /v3/b/`): response 200 `b`: can now be null"]
      )
      expect(third.body).to include(feat)
      expect(third.body).not_to include(chore)
      later = third.body[/^## Later syncs\n\n(.*?)\n\n/m, 1].lines(chomp: true)
      expect(later.map { |line| line[0, 24] }).to eq(
        ["- 2026-11-06 (`feat(spec", "- 2026-11-07 (`feat(spec", "- 2026-11-08 (`chore(spe"]
      )
      expect(third.body.index("## Later syncs")).to be < third.body.index("## Release")
      bump, notes = release(release_commits(third.title, third.body))
      expect([bump, notes.fetch(report_class::API_CHANGES_SECTION).size]).to eq(["minor", 2])
    end

    it "turns a documentation-only pull request into feat when a later sync breaks typed code" do
      previous = own_body("2026-11-05")
      expect(previous).to include("None detected.", chore)
      result = described_class.continue("chore(spec): sync API spec 2026-11-05", previous,
                                        own_body("2026-11-06", breaking: %w[a]))
      expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
      expect(result.body).to start_with("## Breaking changes\n\n#{report_class::BREAKING_INTRO}\n")
      expect(breaking_items(result.body)).to eq(["- `x.a` (`POST /v3/a/`): response 200 `a`: can now be null"])
      expect(result.body).not_to include("None detected", chore)
      expect(result.body.scan(feat).size).to eq(1)
      expect(release(release_commits(result.title, result.body)).first).to eq("minor")
    end

    it "keeps a documentation-only pull request a chore" do
      previous = own_body("2026-11-05").gsub("\n", "\r\n")
      result = described_class.continue("chore(spec): sync API spec 2026-11-05", previous, own_body("2026-11-06"))
      expect(result.title).to eq("chore(spec): sync API spec 2026-11-06")
      expect(result.body).to include("BEGIN_COMMIT_OVERRIDE\nchore(spec): sync API spec 2026-11-06\nEND_COMMIT_OVERRIDE",
                                     "## Breaking changes\n\nNone detected.\n", chore)
      expect(release(release_commits(result.title, result.body))).to eq([nil, {}])
    end

    it "counts earlier syncs as feat when the description has no release block" do
      result = described_class.continue("chore(spec): sync API spec 2026-11-05", "Old description.",
                                        own_body("2026-11-06"))
      expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
      expect(result.body).to start_with(
        "## Breaking changes\n\nNone detected.\n\nThe description had no such list before the sync of 2026-11-06"
      )
      expect(result.body).to include("\nOld description.\n\n## Later syncs\n", "## Release\n\n#{feat}\n")
      expect(result.comment).to include("count as `feat(spec)`")
      # A later sync adds its entries and keeps saying that the list starts late.
      later = described_class.continue(result.title, result.body, own_body("2026-11-07", breaking: %w[a]))
      expect(breaking_items(later.body)).to eq(["- `x.a` (`POST /v3/a/`): response 200 `a`: can now be null"])
      expect(later.body).to include("before the sync of 2026-11-06: changes of earlier syncs")
      expect(later.body.scan("## Breaking changes").size).to eq(1)
    end

    it "keeps a first line someone wrote" do
      previous = "BEGIN_COMMIT_OVERRIDE\nfeat(webhooks): verify the new event\nEND_COMMIT_OVERRIDE\n"
      result = described_class.continue("feat(spec): sync API spec 2026-11-05", previous, own_body("2026-11-06"))
      expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
      expect(release_commits(result.title, result.body)).to eq(
        [["feat", false, "verify the new event"], ["feat", false, "sync API spec 2026-11-06"]]
      )
    end

    it "runs as codegen/sync_pull_request.rb, as the workflow calls it" do
      Dir.mktmpdir("didit-sync-pr") do |dir|
        previous = File.join(dir, "previous.json")
        body = File.join(dir, "body.md")
        File.write(previous, JSON.generate("title" => "chore(spec): sync API spec 2026-11-05",
                                           "body" => own_body("2026-11-05")))
        File.write(body, own_body("2026-11-06", observable: true))
        out = File.join(dir, "continued")
        expect(described_class.main(["--previous", previous, "--body", body, "--out", out])).to eq(0)
        expect(File.read(File.join(out, "title.txt"))).to eq("feat(spec): sync API spec 2026-11-06\n")
        expect(File.read(File.join(out, "body.md")))
          .to include("BEGIN_COMMIT_OVERRIDE\nfeat(spec): sync API spec 2026-11-06\nEND_COMMIT_OVERRIDE")
        expect(File.read(File.join(out, "comment.md"))).to start_with("## Breaking changes\n")

        err = StringIO.new
        File.write(body, "No release block.\n")
        expect(described_class.main(["--previous", previous, "--body", body, "--out", out], err: err)).to eq(1)
        expect(err.string).to include("no release block")
        expect(described_class.main(["--previous", previous], err: err)).to eq(1)
        expect(err.string).to include("--body, --out")
      end
    end
  end
end
