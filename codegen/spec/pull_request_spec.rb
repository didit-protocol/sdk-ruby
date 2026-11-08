# frozen_string_literal: true

require "didit_codegen/sync"
require "stringio"
require_relative "release_please_helper"

# A spec sync pushed on top of commits from people (docs/DESIGN.md section 3.1): the
# description gains its breaking changes and release lines instead of losing them.
RSpec.describe DiditCodegen::Sync::PullRequest do
  let(:feat) { DiditCodegen::Sync::Report::RELEASES.fetch("feat") }
  let(:chore) { DiditCodegen::Sync::Report::RELEASES.fetch("chore") }

  # The pull request body one sync publishes on its own.
  def own_body(date, observable: false, breaking: [])
    report = DiditCodegen::Sync::Report.new(date)
    report.observable = observable
    breaking.each do |field|
      report.breaking << "`x.#{field}` (`POST /v3/#{field}/`): response 200 `#{field}`: can now be null"
    end
    ReleasePlease.published_body(report)
  end

  def item(field)
    "- `x.#{field}` (`POST /v3/#{field}/`): response 200 `#{field}`: can now be null"
  end

  def breaking_items(body)
    body[/^## Breaking changes\n(.*?)(?=^## )/m, 1].lines(chomp: true).grep(/\A- /)
  end

  def release(result)
    ReleasePlease.release(ReleasePlease.commits(result.title, result.body))
  end

  def continue_from(previous_title, previous_body, *syncs)
    syncs.reduce(described_class::Result.new(previous_title, previous_body, nil)) do |result, body|
      described_class.continue(result.title, result.body, body)
    end
  end

  it "adds this sync's breaking changes and release lines to the description, and feat wins" do
    result = continue_from("chore(spec): sync API spec 2026-11-05", "Hand-written intro.\n\n#{own_body("2026-11-05")}",
                           own_body("2026-11-06", breaking: %w[a]))
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
    expect(result.body).to start_with("Hand-written intro.\n")
    expect(result.body).to end_with(
      "BEGIN_COMMIT_OVERRIDE\nfeat(spec): sync API spec 2026-11-06\n\nBEGIN_NESTED_COMMIT\n" \
      "api(spec): #{item("a")[2..]}\nEND_NESTED_COMMIT\nEND_COMMIT_OVERRIDE\n"
    )
    expect(result.comment).not_to include("END_COMMIT_OVERRIDE", "## Release")
    expect(result.comment).to include(item("a"), "## Checks")
    expect(release(result).first).to eq("minor")
  end

  it "keeps feat and every earlier line, once each, through later syncs" do
    result = continue_from("chore(spec): sync API spec 2026-11-05", own_body("2026-11-05"),
                           own_body("2026-11-06", breaking: %w[a]), own_body("2026-11-07", breaking: %w[a b]),
                           own_body("2026-11-08"))
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-08")
    expect([result.body.scan("api(spec): `x.a`").size, result.body.scan("api(spec): `x.b`").size]).to eq([1, 1])
    expect(breaking_items(result.body)).to eq([item("a"), item("b")])
    expect(result.body).to include(feat)
    expect(result.body).not_to include(chore)
    later = result.body[/^## Later syncs\n\n(.*?)\n\n/m, 1].lines(chomp: true)
    expect(later.map { |line| line[0, 24] }).to eq(
      ["- 2026-11-06 (`feat(spec", "- 2026-11-07 (`feat(spec", "- 2026-11-08 (`chore(spe"]
    )
    expect(result.body.index("## Later syncs")).to be < result.body.index("## Release")
    bump, notes = release(result)
    expect([bump, notes.fetch(DiditCodegen::Sync::Report::API_CHANGES_SECTION)]).to eq(["minor", [item("a")[2..],
                                                                                                  item("b")[2..]]])
  end

  it "turns a documentation-only pull request into feat when a later sync breaks typed code" do
    previous = own_body("2026-11-05")
    expect(previous).to include("None detected.", chore)
    result = continue_from("chore(spec): sync API spec 2026-11-05", previous, own_body("2026-11-06", breaking: %w[a]))
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
    expect(result.body).to start_with("## Breaking changes\n\n#{DiditCodegen::Sync::Report::BREAKING_INTRO}\n")
    expect(breaking_items(result.body)).to eq([item("a")])
    expect(result.body).not_to include("None detected", chore)
    expect(result.body.scan(feat).size).to eq(1)
    expect(release(result).first).to eq("minor")
  end

  it "keeps a documentation-only pull request a chore" do
    previous = own_body("2026-11-05").gsub("\n", "\r\n")
    result = continue_from("chore(spec): sync API spec 2026-11-05", previous, own_body("2026-11-06"))
    expect(result.title).to eq("chore(spec): sync API spec 2026-11-06")
    expect(result.body).to include("BEGIN_COMMIT_OVERRIDE\nchore(spec): sync API spec 2026-11-06\n" \
                                   "END_COMMIT_OVERRIDE", "## Breaking changes\n\nNone detected.\n", chore)
    expect(release(result)).to eq([nil, {}])
  end

  it "counts earlier syncs as feat when the description has no release block" do
    result = continue_from("chore(spec): sync API spec 2026-11-05", "Old description.", own_body("2026-11-06"))
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
    expect(result.body).to start_with(
      "## Breaking changes\n\nNone detected.\n\nThe description had no such list before the sync of 2026-11-06"
    )
    expect(result.body).to include("\nOld description.\n\n## Later syncs\n", "## Release\n\n#{feat}\n")
    expect(result.comment).to include("count as `feat(spec)`")
    # A later sync adds its entries and keeps saying that the list starts late.
    later = described_class.continue(result.title, result.body, own_body("2026-11-07", breaking: %w[a]))
    expect(breaking_items(later.body)).to eq([item("a")])
    expect(later.body).to include("before the sync of 2026-11-06: changes of earlier syncs")
    expect(later.body.scan("## Breaking changes").size).to eq(1)
  end

  # The report of a sync with +count+ long breaking changes named after +prefix+.
  def long_report(date, prefix, count)
    report = DiditCodegen::Sync::Report.new(date)
    count.times do |i|
      report.count("`x.#{prefix}#{i}` (`POST /v3/#{prefix}#{i}/`): response `#{"f" * 380}`: can now be null")
    end
    report
  end

  it "reads this sync's lines from its commit message when its description has no release block" do
    report = long_report("2026-11-06", "a", 2)
    body = ReleasePlease.published_body(report).sub(/^BEGIN_COMMIT_OVERRIDE\n.*\nEND_COMMIT_OVERRIDE\n/m, "")
    expect(body).not_to include("BEGIN_COMMIT_OVERRIDE")
    result = described_class.continue("chore(spec): sync API spec 2026-11-05", own_body("2026-11-05"), body,
                                      report.commit_message)
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
    expect(release(result).last.fetch(DiditCodegen::Sync::Report::API_CHANGES_SECTION)).to eq(report.breaking)
    expect { described_class.continue("t", own_body("2026-11-05"), body) }
      .to raise_error(DiditCodegen::Sync::InputError, /no release block/)
  end

  it "leaves the block out once the lines no longer fit, and keeps every line in the commit messages" do
    first = long_report("2026-11-05", "a", 50)
    second = long_report("2026-11-06", "b", 50)
    result = continue_from(first.title, ReleasePlease.published_body(first), ReleasePlease.published_body(second))
    expect(result.body.length).to be <= DiditCodegen::Sync::Report::MAX_BODY
    expect(result.body).not_to include("BEGIN_COMMIT_OVERRIDE", "NESTED_COMMIT", DiditCodegen::Sync::Report::RELEASE_NOTE)
    expect(result.body).to include("The 100 lines for \"#{DiditCodegen::Sync::Report::API_CHANGES_SECTION}\" do not " \
                                   "fit this description", "use the messages of this branch's sync commits")
    squash = "#{first.commit_message}\n#{second.commit_message}"
    expect(ReleasePlease.release(ReleasePlease.commits(squash)).last.fetch(DiditCodegen::Sync::Report::API_CHANGES_SECTION))
      .to eq(first.breaking + second.breaking)
    # A later sync keeps it that way rather than starting a block that misses the earlier lines.
    later = described_class.continue(result.title, result.body, own_body("2026-11-07", breaking: %w[c]))
    expect(later.title).to eq("feat(spec): sync API spec 2026-11-07")
    expect(later.body).not_to include("BEGIN_COMMIT_OVERRIDE")
    expect(later.body).to include(item("c"), "do not fit this description")
  end

  it "keeps a first line someone wrote" do
    previous = "BEGIN_COMMIT_OVERRIDE\nfeat(webhooks): verify the new event\nEND_COMMIT_OVERRIDE\n"
    result = continue_from("feat(spec): sync API spec 2026-11-05", previous, own_body("2026-11-06"))
    expect(result.title).to eq("feat(spec): sync API spec 2026-11-06")
    expect(ReleasePlease.commits(result.title, result.body)).to eq(
      [["feat", false, "verify the new event"], ["feat", false, "sync API spec 2026-11-06"]]
    )
  end

  describe ".main, as the workflow runs codegen/sync_pull_request.rb" do
    around do |example|
      Dir.mktmpdir("didit-sync-pr") do |dir|
        @dir = dir
        example.run
      end
    end

    attr_reader :dir

    def path(name)
      File.join(dir, name)
    end

    def run_main(*args, err: StringIO.new)
      described_class.main(args, err: err)
    end

    before do
      File.write(path("previous.json"), JSON.generate("title" => "chore(spec): sync API spec 2026-11-05",
                                                      "body" => own_body("2026-11-05")))
      File.write(path("body.md"), own_body("2026-11-06", observable: true))
    end

    it "writes the title, the description and the comment" do
      expect(run_main("--previous", path("previous.json"), "--body", path("body.md"), "--out", path("out"))).to eq(0)
      expect(File.read(path("out/title.txt"))).to eq("feat(spec): sync API spec 2026-11-06\n")
      expect(File.read(path("out/body.md")))
        .to include("BEGIN_COMMIT_OVERRIDE\nfeat(spec): sync API spec 2026-11-06\nEND_COMMIT_OVERRIDE")
      expect(File.read(path("out/comment.md"))).to start_with("## Breaking changes\n")
    end

    it "reads the commit message when the body has no release block" do
      File.write(path("body.md"), "## Release\n\nNo block.\n")
      File.write(path("commit.txt"), "feat(spec): sync API spec 2026-11-06\n\nSynced.\n")
      expect(run_main("--previous", path("previous.json"), "--body", path("body.md"), "--out", path("out"),
                      "--commit-message", path("commit.txt"))).to eq(0)
      expect(File.read(path("out/body.md")))
        .to include("BEGIN_COMMIT_OVERRIDE\nfeat(spec): sync API spec 2026-11-06\nEND_COMMIT_OVERRIDE")
    end

    it "exits 1 without a release block or without its options" do
      err = StringIO.new
      File.write(path("body.md"), "No release block.\n")
      expect(run_main("--previous", path("previous.json"), "--body", path("body.md"), "--out", path("out"), err: err))
        .to eq(1)
      expect(run_main("--previous", path("previous.json"), err: err)).to eq(1)
      expect(err.string).to include("no release block", "--body, --out")
      expect(File.exist?(path("out"))).to be(false)
    end
  end
end
