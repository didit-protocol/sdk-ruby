# frozen_string_literal: true

require "didit_codegen/sync"
require "digest"
require_relative "release_please_helper"

# How a spec sync releases (docs/DESIGN.md sections 3.1 and 13): the type and the breaking
# changes of two real upstream changes, and the release-please configuration.
RSpec.describe DiditCodegen::Sync::Report, "#release" do
  fixtures = File.expand_path("fixtures/spec-sync", __dir__)

  # openapi/verification.json at these didit-protocol/sdk-python commits, and the start of its SHA-256.
  let(:pinned) do
    {
      "2026-11-04/before.json" => %w[9fe57fc69299601e59cc7a64c1db370fea5c7461 12b2fdb05572755d],
      "2026-11-04/after.json" => %w[e002a815773bbd1599256e2774046ee76520c6c8 d1783bd862848198],
      "2026-11-06/before.json" => %w[fe9f57a1dfb6374bfd391750d2044fc7a206e4ea 9f8cdf8be8157588],
      "2026-11-06/after.json" => %w[ccc799410f82eee1c25c7ce5abc6caa53846be6b 1b0c7bdd8d7957bd]
    }
  end

  # The API change of 2026-11-04 as every server SDK reports it: [operation, field, kind].
  let(:api_change) do
    decision = "GET /v3/session/{sessionId}/decision/"
    import_shared = "POST /v3/session/import-shared/"
    [
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
  end

  # The report of the sync from <pair>/before.json to <pair>/after.json, the other documents unchanged.
  define_method(:sync_pair) do |pair|
    Dir.mktmpdir("didit-release") do |root|
      ok = { "get" => { "responses" => { "200" => { "description" => "ok" } } } }
      write_repo(root, verification: document({}), account: document({ "/organizations/me/" => ok }))
      FileUtils.cp(File.join(fixtures, pair, "before.json"), File.join(root, "openapi", "verification.json"))
      downloads = %w[account.json authentication.json].to_h { |f| [f, File.binread(File.join(root, "openapi", f))] }
      downloads["verification.json"] = File.binread(File.join(fixtures, pair, "after.json"))
      # The classification only; the generator's own tests cover the generated code.
      allow(DiditCodegen::Generator).to receive(:new).and_return(instance_double(DiditCodegen::Generator, write: []))
      DiditCodegen::Sync.run(root, downloads, date: pair, now: Time.utc(2026, 11, 7, 6, 0, 0)).report
    end
  end

  # [operation, field, kind] of a breaking change in a changed operation's response.
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

  def listed_breaking(summary)
    summary[/^## Breaking changes\n(.*?)^## /m, 1].lines(chomp: true).grep(/\A- /)
  end

  describe "for the pinned upstream changes" do
    it "uses the pinned copies" do
      pinned.each do |name, (_commit, prefix)|
        expect(Digest::SHA256.file(File.join(fixtures, name)).hexdigest).to start_with(prefix), name
      end
    end

    it "releases the API change of 2026-11-04 as feat(spec) with exactly its 14 breaking changes" do
      report = sync_pair("2026-11-04")
      expect(report.title).to eq("feat(spec): sync API spec 2026-11-04")
      expect(report.breaking.map { |text| triple(text) }.sort).to eq(api_change.sort)
      expect(report.breaking.size).to eq(14)
      expect(listed_breaking(report.summary)).to eq(report.breaking.map { |text| "- #{text}" })
      expect(report.breaking).to include(
        "`email.assess_risk` (`POST /v3/email/risk/`): response 200 `email.enrichment.reason_codes[]`: type " \
        "changed from string to object",
        "`kyb.list_shareholders` (`POST /v3/kyb/shareholders/`): response 200, 202 `kyb_registry.registry_data`: " \
        "can now be null"
      )
    end

    it "lists them under API changes that can break typed code in a minor release" do
      report = sync_pair("2026-11-04")
      bump, notes = ReleasePlease.release(ReleasePlease.squash(report))
      expect(bump).to eq("minor")
      expect(notes.fetch("Features")).to eq(["sync API spec 2026-11-04"])
      expect(notes.fetch(described_class::API_CHANGES_SECTION)).to eq(report.breaking)
      expect(notes).not_to have_key("BREAKING CHANGES")
      expect(ReleasePlease.published_body(report) + report.commit_message).not_to include("BREAKING CHANGE")
      expect(ReleasePlease.release(ReleasePlease.commits(report.commit_message))).to eq([bump, notes])
    end

    it "releases nothing for the documentation-only change of 2026-11-06" do
      report = sync_pair("2026-11-06")
      expect(report.title).to eq("chore(spec): sync API spec 2026-11-06")
      expect(report.breaking).to eq([])
      expect(report.summary).to include("## Breaking changes\n\nNone detected.\n",
                                        "- `POST /v3/poa/` (`proof_of_address.verify`): documentation only\n")
      expect(ReleasePlease.squash(report)).to eq([["chore", false, "sync API spec 2026-11-06"]])
      expect(ReleasePlease.release(ReleasePlease.squash(report))).to eq([nil, {}])
    end
  end

  describe "with release-please-config.json" do
    let(:sections) { ReleasePlease.config.fetch("changelog-sections") }

    def release(message, body = nil)
      ReleasePlease.release(ReleasePlease.commits(message, body))
    end

    it "lists the api type first, as API changes that can break typed code, and hides chore" do
      expect(sections.first).to eq("type" => "api", "section" => described_class::API_CHANGES_SECTION)
      by_type = sections.to_h { |section| [section["type"], section] }
      expect(by_type.size).to eq(sections.size)
      expect(by_type.fetch("feat")).to eq("type" => "feat", "section" => "Features")
      expect(by_type.fetch("fix")).not_to have_key("hidden")
      %w[chore docs style refactor test build ci].each { |type| expect(by_type.fetch(type)["hidden"]).to be(true) }
      expect(sections.flat_map(&:keys).uniq.sort).to eq(%w[hidden section type])
    end

    it "releases nothing for chore, ci and docs, and a patch for fix" do
      expect(release("chore(spec): sync API spec 2026-11-06")).to eq([nil, {}])
      expect(release("chore(deps): bump webmock")).to eq([nil, {}])
      expect(release("ci: spec sync releases API changes as minor versions")).to eq([nil, {}])
      expect(release("docs: README versioning")).to eq([nil, {}])
      expect(release("fix: retry on 503")).to eq(["patch", { "Bug Fixes" => ["retry on 503"] }])
    end

    it "reads the override block before the commit, and the title of a merge commit without one" do
      merge = "Merge pull request #31 from didit-protocol/chore/spec-sync\n\nfeat(spec): sync API spec 2026-11-07"
      expect(release(merge).first).to eq("minor")
      report = described_class.new("2026-11-07")
      report.observable = true
      expect(release("chore(spec): sync API spec 2026-11-07", ReleasePlease.published_body(report)).first)
        .to eq("minor")
    end
  end
end
