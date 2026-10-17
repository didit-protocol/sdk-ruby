# frozen_string_literal: true

RSpec.describe DiditCodegen::Generator do
  def naming(resource, method, extra = {})
    { "resource" => resource, "method" => method, "auth" => "api_key", "server" => true }.merge(extra)
  end

  let(:scoped) { "/v3/organization/{organization_id}/application/{application_id}" }
  let(:thing_id) { { "in" => "path", "name" => "thingId", "required" => true, "schema" => { "type" => "string" } } }
  let(:address_ref) { { "$ref" => "#/components/schemas/Address" } }
  let(:email) { { "type" => "object", "properties" => { "email" => { "type" => "string" } } } }

  let(:schemas) do
    {
      "Address" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } },
      "Base" => { "type" => "object", "required" => ["id"], "properties" => { "id" => { "type" => "string" } } },
      "Status" => { "type" => "string", "enum" => ["In Review", "Approved", nil] }
    }
  end

  let(:paths) do
    {
      "/v3/things/" => {
        "get" => operation("List things", naming("things", "list"), "parameters" => [
                             { "in" => "query", "name" => "limit", "schema" => { "type" => "integer" } },
                             { "in" => "query", "name" => "offset", "schema" => { "type" => "integer" } },
                             { "in" => "query", "name" => "status__in", "schema" => { "type" => "string",
                                                                                      "enum" => %w[a b] } }
                           ], "responses" => { "200" => { "description" => "ok", "content" => { "application/json" => {
                             "schema" => { "type" => "object", "properties" => {
                               "count" => { "type" => "integer" }, "next" => { "type" => "string", "nullable" => true },
                               "previous" => { "type" => "string", "nullable" => true },
                               "results" => { "type" => "array", "items" => address_ref }
                             } }
                           } } } }),
        "post" => operation("Create a thing", naming("things", "create"), "parameters" => [
                              { "in" => "header", "name" => "Idempotency-Key", "schema" => { "type" => "string" } }
                            ], "requestBody" => { "content" => { "application/json" => { "schema" => {
                              "type" => "object", "required" => ["name"], "properties" => {
                                "name" => { "type" => "string" }, "retry" => { "type" => "boolean" },
                                "id" => { "type" => "string", "readOnly" => true },
                                "contact" => email,
                                "when" => { "type" => "string", "format" => "date-time" }
                              }
                            } } } }, "responses" => { "201" => { "description" => "ok", "content" => {
                              "application/json" => { "schema" => {
                                "allOf" => [{ "$ref" => "#/components/schemas/Base" }],
                                "properties" => { "status" => { "$ref" => "#/components/schemas/Status" },
                                                  "secret" => { "type" => "string", "writeOnly" => true },
                                                  "created_at" => { "type" => "string", "format" => "date-time" },
                                                  "method" => { "type" => "string" },
                                                  "detail" => { "type" => "object", "properties" => {
                                                    "score" => { "type" => "number" }
                                                  } } }
                              } }
                            } } })
      },
      "/v3/things/{thingId}/pdf/" => {
        "get" => operation("PDF", naming("things", "download_pdf"), "parameters" => [
                             thing_id
                           ], "responses" => { "200" => { "description" => "ok",
                                                          "content" => { "application/pdf" => {} } } })
      },
      "/v3/things/{thingId}/photo/" => {
        "post" => operation("Upload", naming("things.photos", "upload"), "parameters" => [
                              thing_id
                            ], "requestBody" => { "content" => { "multipart/form-data" => { "schema" => {
                              "type" => "object", "required" => ["photo"], "properties" => {
                                "photo" => { "type" => "string",
                                             "format" => "binary" }, "note" => { "type" => "string" }
                              }
                            } } } }, "responses" => { "204" => { "description" => "none" } })
      },
      "#{scoped}/cases/{case_uuid}/" => {
        "delete" => operation("Delete", naming("cases", "delete", "scope" => "application"), "parameters" => [
                                { "in" => "path", "name" => "organization_id", "required" => true, "schema" => {} },
                                { "in" => "path", "name" => "application_id", "required" => true, "schema" => {} },
                                { "in" => "path", "name" => "case_uuid", "required" => true, "schema" => {} }
                              ], "responses" => { "204" => { "description" => "none" } })
      },
      "/v3/device/" => {
        "post" => operation("Device only", naming("device", "call", "server" => false, "auth" => "device_token"),
                            "responses" => { "200" => { "description" => "ok" } })
      }
    }
  end

  def build(dir, verification: document(paths, schemas), **options)
    write_repo(dir, verification: verification, **options)
    described_class.new(dir)
  end

  around do |example|
    Dir.mktmpdir("didit-codegen") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  describe "naming (docs/DESIGN.md section 4)" do
    it "fails with a clear message for an operation without naming" do
      paths["/v3/new/"] = { "post" => { "operationId" => "new_thing", "responses" => {} } }
      expect { build(dir) }.to raise_error(DiditCodegen::Error) do |error|
        expect(error.message).to include("These operations have no SDK naming")
        expect(error.message).to include("POST /v3/new/ (operationId new_thing)")
        expect(error.message).to include("openapi/overlay.json")
      end
    end

    it "uses the overlay when upstream has no naming, and upstream when it has" do
      paths["/v3/new/"] = { "post" => { "responses" => {} } }
      generator = build(dir, overlay: { "POST /v3/new/" => naming("extras", "make") })
      expect(generator.methods.map { |m| "#{m.resource}.#{m.name}" }).to include("extras.make")
    end

    it "fails on overlay entries for operations that no longer exist" do
      expect { build(dir, overlay: { "GET /v3/gone/" => naming("gone", "list") }) }
        .to raise_error(DiditCodegen::Error, %r{no longer exist upstream.*\n  GET /v3/gone/}m)
    end

    it "fails on duplicate names and on methods that clash with nested resources" do
      paths["/v3/other/"] = { "get" => operation("x", naming("things", "list")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /both map to things.list/)
      paths.delete("/v3/other/")
      paths["/v3/clash/"] = { "get" => operation("x", naming("things", "photos")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /clashes with the nested resource "things.photos"/)
    end

    it "fails on invalid naming values and on scope mismatches" do
      paths["/v3/bad/"] = { "get" => operation("x", naming("Bad-Name", "list")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /dot path of snake_case names/)
      paths["/v3/bad/"] = { "get" => operation("x", naming("bad", "list", "auth" => "cookie")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /auth "cookie"/)
      paths["/v3/bad/"] = { "get" => operation("x", naming("bad", "list", "scope" => "application")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /scope application needs a path/)
    end

    it "refuses names that would replace built-in methods" do
      paths["/v3/send/"] = { "post" => operation("x", naming("things", "send")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /built-in Ruby method/)
      paths.delete("/v3/send/")
      paths["/v3/opts/"] = { "get" => operation("x", naming("with_options", "list")) }
      expect { build(dir) }.to raise_error(DiditCodegen::Error, /Didit::Client#with_options/)
    end

    it "exposes server operations only" do
      names = build(dir).methods.map { |m| "#{m.resource}.#{m.name}" }
      expect(names).to contain_exactly("cases.delete", "things.create", "things.download_pdf", "things.list",
                                       "things.photos.upload")
    end
  end

  describe "types (docs/DESIGN.md section 5.1)" do
    let(:files) { build(dir).files }

    it "keeps component names and names inline types after their parent" do
      types = files.fetch("lib/didit/types/things.rb")
      expect(files.fetch("lib/didit/types/components.rb")).to include("class Address < Didit::Model")
      expect(types).to include("class ThingsCreateResponse < Base")
      expect(types).to include("class ThingsCreateResponseDetail < Didit::Model")
      expect(types).to include('field :detail, "detail", "ThingsCreateResponseDetail"')
      expect(types).to include('field :score, "score", :float')
      expect(types).to include('field :created_at, "created_at", :datetime')
      expect(types).to include('field :method_, "method", :string')
      expect(types).not_to include('"secret"')
      rbs = files.fetch("sig/didit/types/things.rbs")
      expect(rbs).to include("type things_create_params_contact = { ?email: String }")
      expect(rbs).to include("def method_: () -> String?")
    end

    it "writes open enums as frozen string constants" do
      components = files.fetch("lib/didit/types/components.rb")
      expect(components).to include(%(module Status\n      IN_REVIEW = "In Review"\n      APPROVED = "Approved"))
      expect(components).to include("VALUES = [IN_REVIEW, APPROVED].freeze")
      expect(files.fetch("lib/didit/types/things.rb")).to include("module ThingsListParamsStatusIn")
    end

    it "registers every type for autoloading" do
      index = files.fetch("lib/didit/types.rb")
      expect(index).to include('autoload :Address, "didit/types/components"')
      expect(index).to include('autoload :ThingsCreateResponse, "didit/types/things"')
    end
  end

  describe "methods" do
    let(:files) { build(dir).files }
    let(:things) { files.fetch("lib/didit/resources/things.rb") }

    it "takes path ids positionally and everything else as keywords" do
      expect(things).to include("def create(name:, retry: OMIT, contact: OMIT, when: OMIT, idempotency_key: OMIT, " \
                                "request_options: nil)")
      expect(things).to include('"retry" => binding.local_variable_get(:retry)')
      expect(things).to include('headers: { "Idempotency-Key" => idempotency_key }')
      expect(things).not_to include('"id" =>')
      expect(things).to include("def download_pdf(thing_id, request_options: nil, &block)")
      expect(things).to include('accept: "application/pdf, application/json"')
      expect(things).to include("def list(limit: OMIT, offset: OMIT, status_in: OMIT, request_options: nil)")
      expect(things).to include("page: Types::Address")
      expect(things).to include("encoding: :multipart")
      expect(things).to include("file_fields: %w[photo]")
    end

    it "fills the application scope from the client" do
      cases = files.fetch("lib/didit/resources/cases.rb")
      expect(cases).to include("def delete(case_uuid, request_options: nil)")
      expect(cases).to include("scope: :application")
    end

    it "writes matching RBS signatures" do
      rbs = files.fetch("sig/didit/resources/things.rbs")
      expect(rbs).to include("def create: (name: String, ?retry: bool, " \
                             "?contact: Didit::Types::things_create_params_contact, ?when: Time | String, ?idempotency_key: String, ?request_options: Didit::request_options?) " \
                             "-> Didit::Types::ThingsCreateResponse")
      expect(rbs).to include("def list: (?limit: Integer, ?offset: Integer, ?status_in: String, " \
                             "?request_options: Didit::request_options?) -> Didit::Page[Didit::Types::Address]")
      expect(rbs).to include("{ (String chunk) -> void } -> nil")
    end

    it "keeps deprecated operations with a warning" do
      deprecated = { "description" => "x", "methods" => { "things.old" => {
        "reason" => "removed", "operation_key" => "GET /v3/old/", "x-didit-sdk" => naming("things", "old"),
        "operation" => { "summary" => "Old", "responses" => { "204" => { "description" => "none" } } },
        "since" => "2026-10-01", "deprecated_since" => "0.1.0", "remove_in" => "0.2.0"
      } } }
      source = build(dir, deprecated: deprecated).files.fetch("lib/didit/resources/things.rb")
      expect(source).to include("# @deprecated Removed from the API contract; this method is removed in version 0.2.0.")
      expect(source).to include('@client.deprecated("things.old", ')
    end

    it "writes one test per operation" do
      spec = files.fetch("spec/generated/things_spec.rb")
      expect(spec.scan(/^  it "/).size).to eq(4)
      expect(spec).to include('it "things.photos.upload sends POST /v3/things/{thingId}/photo/"')
    end
  end

  describe "files" do
    it "starts every file with the generated header and produces valid Ruby" do
      build(dir).files.each do |path, content|
        expect(content).to start_with(DiditCodegen::HEADER), path
        RubyVM::InstructionSequence.compile(content, path) if path.end_with?(".rb")
      end
    end

    it "writes, then reports nothing to change; reports edits, missing and stale files" do
      generator = build(dir)
      expect(generator.write).not_to be_empty
      expect(generator.check.values.flatten).to eq([])
      expect(generator.write).to eq([])

      File.write(File.join(dir, "lib/didit/resources/things.rb"), "# edited")
      File.delete(File.join(dir, "sig/didit/resources/cases.rbs"))
      File.write(File.join(dir, "lib/didit/types/old.rb"), "#{DiditCodegen::HEADER}\n")
      result = generator.check
      expect(result[:changed]).to eq(["lib/didit/resources/things.rb"])
      expect(result[:missing]).to eq(["sig/didit/resources/cases.rbs"])
      expect(result[:stale]).to eq(["lib/didit/types/old.rb"])
      generator.write
      expect(File.exist?(File.join(dir, "lib/didit/types/old.rb"))).to be(false)
    end

    it "refuses hand-written files in generated directories" do
      generator = build(dir)
      generator.write
      File.write(File.join(dir, "lib/didit/types/mine.rb"), "# hand-written\n")
      expect { generator.check }.to raise_error(DiditCodegen::Error, /was not generated/)
    end
  end
end
