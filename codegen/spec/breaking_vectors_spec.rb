# frozen_string_literal: true

require "didit_codegen/sync"
require "digest"

# The breaking-change rules of docs/DESIGN.md section 3.1, checked by the vectors every server
# SDK shares: openapi/breaking-vectors.json is generated in sdk-python and copied byte for
# byte, and each of its cases must give the same type and the same breaking changes here.
# A case that looks wrong is reported to sdk-python, never skipped or edited here.
RSpec.describe DiditCodegen::Sync, ".classify" do
  openapi = File.expand_path("../../openapi", __dir__)
  vectors = JSON.parse(File.read(File.join(openapi, "breaking-vectors.json"), encoding: "UTF-8"))

  it "uses the copy recorded in openapi/SOURCE.json, byte for byte" do
    source = JSON.parse(File.read(File.join(openapi, "SOURCE.json"), encoding: "UTF-8")).fetch("breaking-vectors.json")
    expect(Digest::SHA256.file(File.join(openapi, "breaking-vectors.json")).hexdigest).to eq(source.fetch("sha256"))
    expect(vectors).to include("version" => 1, "rules" => "docs/DESIGN.md section 3.1")
  end

  it "has cases for every rule of docs/DESIGN.md section 3.1" do
    names = vectors.fetch("cases").map { |c| c.fetch("name") }
    expect(names.uniq).to eq(names)
    expect(vectors.fetch("cases").map { |c| c.fetch("rule") }.uniq)
      .to match_array(["Responses", "Requests", "Operations", "Unions", "Success statuses", "Release notes"])
  end

  vectors.fetch("cases").each do |vector|
    it "#{vector.fetch("rule")}: #{vector.fetch("name")}" do
      expected = vector.fetch("expect")
      expect(described_class.classify(vector.fetch("before"), vector.fetch("after")))
        .to eq([expected.fetch("type"), expected.fetch("breaking")])
    end
  end
end
