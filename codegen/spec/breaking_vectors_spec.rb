# frozen_string_literal: true

require "didit_codegen/sync"
require "digest"

# The breaking-change rules of docs/DESIGN.md section 3.1, checked by the vectors every server
# SDK shares: openapi/breaking-vectors.json is generated in sdk-python and copied byte for
# byte, and each of its cases must give the same type and the same breaking changes here.
# A case that looks wrong is reported to sdk-python, never skipped or edited here.
module BreakingVectors
  OPENAPI = File.expand_path("../../openapi", __dir__)
  FILE = File.join(OPENAPI, "breaking-vectors.json")

  def self.document
    JSON.parse(File.read(FILE, encoding: "UTF-8"))
  end

  RSpec.describe DiditCodegen::Sync, ".classify" do
    let(:vectors) { BreakingVectors.document }

    it "uses the copy recorded in openapi/SOURCE.json, byte for byte" do
      source = JSON.parse(File.read(File.join(OPENAPI, "SOURCE.json"), encoding: "UTF-8"))
      expect(Digest::SHA256.file(FILE).hexdigest).to eq(source.fetch("breaking-vectors.json").fetch("sha256"))
      expect(vectors).to include("version" => 1, "rules" => "docs/DESIGN.md section 3.1")
    end

    it "has cases for every rule of docs/DESIGN.md section 3.1" do
      names = vectors.fetch("cases").map { |c| c.fetch("name") }
      expect(names.uniq).to eq(names)
      expect(vectors.fetch("cases").map { |c| c.fetch("rule") }.uniq)
        .to contain_exactly("Responses", "Requests", "Operations", "Unions", "Success statuses", "Release notes")
    end

    BreakingVectors.document.fetch("cases").each do |vector|
      it "#{vector.fetch("rule")}: #{vector.fetch("name")}" do
        expected = vector.fetch("expect")
        expect(described_class.classify(vector.fetch("before"), vector.fetch("after")))
          .to eq([expected.fetch("type"), expected.fetch("breaking")])
      end
    end
  end
end
