# frozen_string_literal: true

require "didit_codegen/sync"
require "open3"
require "rbconfig"
require "stringio"
require "webmock/rspec"

# The spec sync (codegen/spec_sync.rb) on small synthetic repositories. Nothing here reads
# the live openapi/ files or touches the network.
RSpec.describe "spec sync" do
  let(:now) { Time.utc(2026, 10, 18, 6, 41, 7) }
  let(:fetched_at) { "2026-10-18T06:41:07Z" }
  let(:date) { "2026-10-18" }

  around do |example|
    Dir.mktmpdir("didit-spec-sync") do |dir|
      @root = dir
      example.run
    end
  end

  attr_reader :root

  # Fixture documents ----------------------------------------------------------------

  def naming(resource, method, extra = {})
    { "auth" => "api_key", "method" => method, "resource" => resource, "server" => true }.merge(extra)
  end

  def ref(name)
    { "$ref" => "#/components/schemas/#{name}" }
  end

  def ok(schema, status = "200", example: nil)
    media = { "schema" => schema }
    media["example"] = example if example
    { status => { "description" => "ok", "content" => { "application/json" => media } } }
  end

  def body(schema)
    { "required" => true, "content" => { "application/json" => { "schema" => schema } } }
  end

  def op(summary, responses:, body: nil, parameters: nil, naming: nil)
    out = { "summary" => summary, "operationId" => summary.downcase.tr(" ", "_"), "responses" => responses }
    out["requestBody"] = body if body
    out["parameters"] = parameters if parameters
    out["x-didit-sdk"] = naming if naming
    out
  end

  def path_param(name)
    { "in" => "path", "name" => name, "required" => true, "schema" => { "type" => "string" } }
  end

  # A JWT-shaped string, built at run time so that no committed file carries one.
  def jwt
    %w[eyJ aGVhZGVy . eyJ cGF5bG9hZA . c2lnbmF0dXJl].join
  end

  def schemas
    {
      "BillingBalance" => { "type" => "object", "required" => %w[balance],
                            "properties" => { "balance" => { "type" => "string" },
                                              "currency" => { "type" => "string" } } },
      "SessionRequest" => {
        "type" => "object", "required" => %w[workflow_id],
        "properties" => {
          "workflow_id" => { "type" => "string" }, "vendor_data" => { "type" => "string" },
          "title" => { "type" => "string" }, "callback" => { "type" => "string" },
          "language" => { "type" => "string", "enum" => %w[en es fr] }
        }
      },
      "Session" => {
        "type" => "object", "required" => %w[session_id status],
        "properties" => {
          "session_id" => { "type" => "string" }, "title" => { "type" => "string" },
          "status" => { "type" => "string", "enum" => ["Not Started", "In Progress", "Approved"] },
          "url" => { "type" => "string" }
        }
      }
    }
  end

  def verification_paths
    {
      "/v3/billing/balance/" => { "get" => op("Get the balance", responses: ok(ref("BillingBalance"))) },
      "/v3/billing/top-up/" => {
        "post" => op("Top up", body: body({ "type" => "object", "required" => %w[amount],
                                            "properties" => { "amount" => { "type" => "number" },
                                                              "note" => { "type" => "string" } } }),
                               responses: ok({ "type" => "object",
                                               "properties" => { "checkout_url" => { "type" => "string" } } }))
      },
      "/v3/session/" => {
        "post" => op("Create a session", body: body(ref("SessionRequest")), responses: ok(ref("Session"), "201"))
      },
      "/v3/session/{sessionId}/decision/" => {
        "parameters" => [path_param("sessionId")],
        "get" => op("Get the decision", responses: ok(ref("Session")),
                                        naming: naming("sessions", "retrieve_decision"))
      },
      "/v3/device/" => { "post" => op("Device call", responses: ok({ "type" => "object" })) }
    }
  end

  def account_paths
    {
      "/programmatic/login/" => {
        "post" => op("Log in", body: body({ "type" => "object", "required" => %w[email password],
                                            "properties" => { "email" => { "type" => "string" },
                                                              "password" => { "type" => "string" } } }),
                               responses: ok({ "type" => "object",
                                               "properties" => { "access_token" => { "type" => "string" } } },
                                             example: { "access_token" => jwt }))
      },
      "/organizations/me/" => {
        "get" => op("List organizations",
                    responses: ok({ "type" => "array",
                                    "items" => { "type" => "object",
                                                 "properties" => { "uuid" => { "type" => "string" } } } }))
      },
      "/organizations/me/{org_id}/applications/" => {
        "get" => op("List applications", parameters: [path_param("org_id")],
                                         responses: ok({ "type" => "array", "items" => { "type" => "object" } }))
      }
    }
  end

  def base_overlay
    {
      "GET /v3/billing/balance/" => naming("billing", "retrieve_balance"),
      "POST /v3/billing/top-up/" => naming("billing", "top_up"),
      "POST /v3/session/" => naming("sessions", "create"),
      "POST /v3/device/" => naming("device", "call", "auth" => "device_token", "server" => false),
      "account POST /programmatic/login/" => naming("account", "login", "auth" => "none"),
      "account GET /organizations/me/" => naming("account.organizations", "list", "auth" => "account_token"),
      "account GET /organizations/me/{org_id}/applications/" =>
        naming("account.applications", "list", "auth" => "account_token")
    }
  end

  def verification(paths = verification_paths, components = schemas)
    document(paths, components)
  end

  def account(paths = account_paths)
    document(paths)
  end

  # The seeded layout of openapi/SOURCE.json: one-space indent, no trailing newline.
  def source_text(verification_sha, account_sha)
    <<~JSON.chomp
      {
       "verification.json": {
        "url": "https://docs.didit.me/openapi-25.json",
        "sha256": "#{verification_sha}",
        "fetched_at": "2026-10-17T10:00:00Z"
       },
       "account.json": {
        "url": "https://docs.didit.me/openapi-auth.json",
        "sha256": "#{account_sha}",
        "fetched_at": "2026-10-17T10:00:00Z"
       },
       "webhook-vectors.json": {
        "generator": "make_vectors.py (seeded 2026-10-17)",
        "source": "service@0000000 webhooks.py"
       }
      }
    JSON
  end

  # Writes the fixture repository; overlay.json gets the seeded one-space layout.
  def repo(overlay: base_overlay, deprecated: nil, version: "0.1.0", **docs)
    write_repo(root, verification: docs.fetch(:verification) { verification }, account: docs.fetch(:account) { account },
                     deprecated: deprecated, version: version)
    overlay_file = { "description" => "test overlay", "version" => 1, "operations" => overlay.sort.to_h }
    File.write(openapi("overlay.json"), JSON.pretty_generate(overlay_file, indent: " "))
    File.write(openapi("SOURCE.json"), source_text(sha("verification.json"), sha("account.json")))
  end

  def openapi(file)
    File.join(root, "openapi", file)
  end

  def sha(file)
    Digest::SHA256.file(openapi(file)).hexdigest
  end

  def read_json(file)
    JSON.parse(File.read(openapi(file), encoding: "UTF-8"))
  end

  def upstream_dir
    File.join(root, "upstream")
  end

  # The documents the next sync downloads; unspecified ones are the current openapi/ copies.
  def upstream(verification: nil, account: nil)
    FileUtils.mkdir_p(upstream_dir)
    { "verification.json" => verification, "account.json" => account }.each do |file, doc|
      bytes = if doc.nil? then File.binread(openapi(file))
              elsif doc.is_a?(String) then doc
              else JSON.generate(doc)
              end
      File.binwrite(File.join(upstream_dir, file), bytes)
    end
  end

  def snapshot
    Dir.glob("**/*", base: root).select { |p| File.file?(File.join(root, p)) }.sort
       .to_h { |p| [p, File.binread(File.join(root, p))] }
  end

  attr_reader :out, :err, :summary, :commit_message, :github_output

  # Runs the CLI in-process on the fixture repository; returns the exit code.
  def sync(*args, env: {}, downloader: nil)
    @out = StringIO.new
    @err = StringIO.new
    summary_file = File.join(root, "summary.md")
    commit_file = File.join(root, "commit.txt")
    output_file = File.join(root, "github_output")
    options = { root: root, env: { "GITHUB_OUTPUT" => output_file }.merge(env), out: @out, err: @err, now: -> { now } }
    options[:downloader] = downloader if downloader
    source = downloader ? [] : ["--from-dir", upstream_dir]
    code = DiditCodegen::Sync::CLI.new(**options).run(
      [*source, "--summary", summary_file, "--commit-message", commit_file, "--date", date, *args]
    )
    @summary = File.exist?(summary_file) ? File.read(summary_file, encoding: "UTF-8") : nil
    @commit_message = File.exist?(commit_file) ? File.read(commit_file, encoding: "UTF-8") : nil
    @github_output = File.exist?(output_file) ? File.read(output_file, encoding: "UTF-8").lines(chomp: true) : nil
    [summary_file, commit_file, output_file].each { |f| FileUtils.rm_f(f) }
    code
  end

  def section(heading)
    summary.split(/^## /).find { |s| s.start_with?("#{heading}\n") }.to_s
  end

  def generated(path)
    full = File.join(root, path)
    File.exist?(full) ? File.read(full, encoding: "UTF-8") : nil
  end

  # Scenarios ------------------------------------------------------------------------

  describe "without an upstream change" do
    it "prints No upstream change, writes nothing and reports changed=false" do
      repo
      upstream
      before = snapshot
      expect(sync).to eq(0)
      expect(out.string).to eq("No upstream change\n")
      expect(snapshot).to eq(before)
      expect(github_output).to eq(["changed=false", "breaking=false", "date=#{date}"])
      expect(commit_message).to be_nil
    end
  end

  describe "with a changed spec" do
    before do
      repo
      changed = verification
      changed["paths"]["/v3/billing/balance/"]["get"]["parameters"] = [
        { "in" => "query", "name" => "currency", "schema" => { "type" => "string" } }
      ]
      changed["components"]["schemas"]["Session"]["properties"]["expires_at"] = { "type" => "string" }
      changed["components"]["schemas"]["Session"]["properties"]["status"]["enum"] << "Declined"
      changed["components"]["schemas"]["Extra"] = { "type" => "object" }
      upstream(verification: changed)
    end

    it "copies the download byte for byte, regenerates and summarises the changes" do
      overlay_before = File.binread(openapi("overlay.json"))
      account_before = File.binread(openapi("account.json"))
      expect(sync).to eq(0)
      expect(File.binread(openapi("verification.json"))).to eq(File.binread(File.join(upstream_dir,
                                                                                      "verification.json")))
      expect(File.binread(openapi("account.json"))).to eq(account_before)
      expect(File.binread(openapi("overlay.json"))).to eq(overlay_before)
      expect(File.exist?(openapi("deprecated-operations.json"))).to be(false)
      expect(generated("lib/didit/resources/billing.rb")).to include("def retrieve_balance(")
      expect(generated("spec/generated/billing_spec.rb")).to include("retrieve_balance")

      expect(summary.lines.first).to eq("chore(spec): sync API spec 2026-10-18\n")
      expect(summary.lines[1]).to eq("\n")
      expect(summary).to include("| `openapi/verification.json` | https://docs.didit.me/openapi-25.json | " \
                                 "`#{Digest::SHA256.hexdigest(JSON.pretty_generate(verification))}` | " \
                                 "`#{sha('verification.json')}` |")
      expect(summary).to match(%r{\| `openapi/account\.json` \| https://docs\.didit\.me/openapi-auth\.json \| `\h{64}` \| unchanged \|})
      expect(section("Breaking changes")).to include("None detected.")
      changed = section("Operations")
      expect(changed).to include("`GET /v3/billing/balance/` (`billing.retrieve_balance`)\n  - query parameter " \
                                 "`currency`: added")
      expect(changed).to include("response 201 `expires_at`: field added")
      expect(changed).to include("response 201 `status`: enum value `Declined` added")
      expect(section("Schemas")).to include("`Extra` added (verification.json)", "`Session` changed (verification.json)")
      expect(commit_message).to start_with("chore(spec): sync API spec 2026-10-18\n\n")
      expect(commit_message).not_to include("BREAKING CHANGE")
      expect(github_output).to eq(["changed=true", "breaking=false", "date=2026-10-18"])
    end

    it "updates SOURCE.json in its exact layout and keeps the webhook-vectors.json entry" do
      account_sha = sha("account.json")
      expect(sync).to eq(0)
      expected = source_text(sha("verification.json"), account_sha)
                 .sub(/("sha256": "#{sha('verification.json')}",\n  "fetched_at": )"[^"]+"/, "\\1\"#{fetched_at}\"")
      expect(File.read(openapi("SOURCE.json"), encoding: "UTF-8")).to eq(expected)
      expect(expected).to include(%("fetched_at": "#{fetched_at}"), %("fetched_at": "2026-10-17T10:00:00Z"))
      expect(expected).not_to end_with("\n")
    end
  end

  describe "SDK naming upstream (docs/DESIGN.md section 3)" do
    it "deletes an overlay entry when upstream carries the same x-didit-sdk" do
      repo
      changed = verification
      changed["paths"]["/v3/billing/top-up/"]["post"]["x-didit-sdk"] = naming("billing", "top_up")
      upstream(verification: changed)
      expect(sync).to eq(0)
      overlay = File.read(openapi("overlay.json"), encoding: "UTF-8")
      remaining = base_overlay.reject { |k, _| k == "POST /v3/billing/top-up/" }.sort.to_h
      expect(overlay).to eq(JSON.pretty_generate({ "description" => "test overlay", "version" => 1,
                                                   "operations" => remaining }, indent: " "))
      expect(section("SDK naming")).to include("`POST /v3/billing/top-up/`: overlay entry deleted, upstream " \
                                               "carries the same `x-didit-sdk`")
      expect(section("Breaking changes")).to include("None detected.")
      expect(generated("lib/didit/resources/billing.rb")).to include("def top_up(")
    end

    it "lets a different upstream value win and says old -> new" do
      repo
      changed = verification
      changed["paths"]["/v3/billing/top-up/"]["post"]["x-didit-sdk"] = naming("billing", "top_up",
                                                                              "auth" => "account_token")
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(read_json("overlay.json")["operations"]).not_to have_key("POST /v3/billing/top-up/")
      expect(section("SDK naming")).to include(
        "`POST /v3/billing/top-up/`: overlay entry deleted, upstream `x-didit-sdk` differs and wins: " \
        "`#{JSON.generate(naming('billing', 'top_up'))}` -> " \
        "`#{JSON.generate(naming('billing', 'top_up', 'auth' => 'account_token'))}`",
        "auth changed from `api_key` to `account_token`"
      )
      expect(section("Breaking changes")).to include("`billing.top_up` (`POST /v3/billing/top-up/`): now " \
                                                     "authenticates with `account_token` instead of `api_key`")
    end
  end

  describe "removed operations (docs/DESIGN.md section 3.1)" do
    it "keeps the method as deprecated for one minor version" do
      repo(version: "0.4.2")
      changed = verification
      changed["paths"].delete("/v3/billing/balance/")
      upstream(verification: changed)
      expect(sync).to eq(0)

      entry = read_json("deprecated-operations.json")["methods"]["billing.retrieve_balance"]
      expect(entry).to include("reason" => "removed", "operation_key" => "GET /v3/billing/balance/",
                               "x-didit-sdk" => naming("billing", "retrieve_balance"), "since" => date,
                               "deprecated_since" => "0.4.2", "remove_in" => "0.5.0")
      expect(entry.keys).to eq(%w[reason operation_key x-didit-sdk since deprecated_since remove_in note operation])
      expect(JSON.generate(entry)).not_to include("$ref")
      expect(entry.dig("operation", "responses", "200", "content", "application/json", "schema", "properties"))
        .to eq(schemas["BillingBalance"]["properties"])
      expect(read_json("overlay.json")["operations"]).not_to have_key("GET /v3/billing/balance/")

      billing = generated("lib/didit/resources/billing.rb")
      expect(billing).to include("def retrieve_balance(", "# @deprecated Removed from the API contract on " \
                                                          "2026-10-18; this deprecated method is kept through " \
                                                          "version 0.5.0.")
      expect(billing).to include("def top_up(")
      expect(generated("spec/generated/billing_spec.rb")).to include("retrieve_balance")
      expect(section("Breaking changes")).to include("`billing.retrieve_balance` (`GET /v3/billing/balance/`) was " \
                                                     "removed upstream; the method is deprecated and kept through " \
                                                     "version 0.5.0")
      expect(section("Operations")).to include("### Removed (1)", "`GET /v3/billing/balance/` " \
                                                                  "(`billing.retrieve_balance`): deprecated")
      expect(section("Deprecations")).to include("### Added (1)", "`billing.retrieve_balance`: deprecated")
      expect(commit_message).to include("\n\nBREAKING CHANGE: the API spec sync changes the SDK surface.\n- " \
                                        "`billing.retrieve_balance`")
      expect(github_output).to eq(["changed=true", "breaking=true", "date=2026-10-18"])
    end

    it "dereferences path-item parameters and scrubs credential-like examples" do
      repo
      changed_account = account
      changed_account["paths"].delete("/programmatic/login/")
      changed = verification
      changed["paths"].delete("/v3/session/{sessionId}/decision/")
      upstream(verification: changed, account: changed_account)
      expect(sync).to eq(0)
      methods = read_json("deprecated-operations.json")["methods"]
      expect(methods.keys).to eq(%w[account.login sessions.retrieve_decision])
      login = JSON.generate(methods["account.login"])
      expect(login).not_to include("eyJ")
      expect(methods.dig("account.login", "operation", "responses", "200", "content", "application/json",
                         "example")).to eq("access_token" => "redacted-jwt")
      decision = methods["sessions.retrieve_decision"]["operation"]
      expect(decision["parameters"]).to eq([path_param("sessionId")])
      expect(decision).not_to have_key("x-didit-sdk")
      expect(generated("lib/didit/resources/account.rb")).to include("def login(")
      expect(generated("lib/didit/resources/sessions.rb")).to include("def retrieve_decision(session_id")
    end

    it "treats an operation whose name reappears on another path as moved" do
      repo
      changed = verification
      item = changed["paths"].delete("/v3/billing/balance/")
      item["get"]["x-didit-sdk"] = naming("billing", "retrieve_balance")
      changed["paths"]["/v4/billing/balance/"] = item
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(File.exist?(openapi("deprecated-operations.json"))).to be(false)
      expect(section("Operations")).to include("### Moved (1)", "`billing.retrieve_balance`: moved from " \
                                                                "`GET /v3/billing/balance/` to " \
                                                                "`GET /v4/billing/balance/`; same parameters")
      expect(section("Breaking changes")).to include("None detected.")
      expect(generated("lib/didit/resources/billing.rb")).to include("+GET /v4/billing/balance/+")
    end

    it "reports what a moved operation changed" do
      repo
      changed = verification
      item = changed["paths"].delete("/v3/billing/balance/")
      item["get"]["x-didit-sdk"] = naming("billing", "retrieve_balance")
      item["get"]["parameters"] = [{ "in" => "query", "name" => "currency", "required" => true,
                                     "schema" => { "type" => "string" } }]
      changed["paths"]["/v4/billing/balance/"] = item
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(section("Breaking changes")).to include("`billing.retrieve_balance` moved from " \
                                                     "`GET /v3/billing/balance/` to `GET /v4/billing/balance/`: " \
                                                     "query parameter `currency`: new required parameter")
    end

    it "removes an operation that stopped being a server operation at once" do
      repo
      changed = verification
      changed["paths"]["/v3/billing/top-up/"]["post"]["x-didit-sdk"] =
        naming("billing", "top_up", "auth" => "device_token", "server" => false)
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(File.exist?(openapi("deprecated-operations.json"))).to be(false)
      expect(generated("lib/didit/resources/billing.rb")).not_to include("def top_up(")
      expect(section("Breaking changes")).to include("`billing.top_up` (`POST /v3/billing/top-up/`) is removed: " \
                                                     "the operation now needs `device_token`")
      expect(section("Operations")).to include("no longer a server operation (auth `device_token`)")
    end
  end

  describe "renamed operations" do
    it "keeps the old name as a deprecated alias, and renaming back drops it" do
      repo
      changed = verification
      changed["paths"]["/v3/billing/balance/"]["get"]["x-didit-sdk"] = naming("billing", "get_balance")
      upstream(verification: changed)
      expect(sync).to eq(0)
      entry = read_json("deprecated-operations.json")["methods"]["billing.retrieve_balance"]
      expect(entry).to include("reason" => "renamed", "replacement" => "billing.get_balance",
                               "operation_key" => "GET /v3/billing/balance/")
      billing = generated("lib/didit/resources/billing.rb")
      expect(billing).to include("def get_balance(", "def retrieve_balance(",
                                 "# @deprecated Renamed to billing.get_balance on 2026-10-18")
      expect(section("Operations")).to include("`GET /v3/billing/balance/`: `billing.retrieve_balance` renamed to " \
                                               "`billing.get_balance`")
      expect(section("Breaking changes")).to include("`billing.retrieve_balance` was renamed upstream to " \
                                                     "`billing.get_balance`")

      changed["paths"]["/v3/billing/balance/"]["get"]["x-didit-sdk"] = naming("billing", "retrieve_balance")
      upstream(verification: changed)
      expect(sync).to eq(0)
      methods = read_json("deprecated-operations.json")["methods"]
      expect(methods.keys).to eq(["billing.get_balance"])
      expect(methods["billing.get_balance"]["replacement"]).to eq("billing.retrieve_balance")
      expect(section("Deprecations")).to include("### No longer deprecated (1)", "`billing.retrieve_balance`: " \
                                                                                 "provided again by " \
                                                                                 "`GET /v3/billing/balance/`")
    end

    it "calls out a name that now belongs to another operation" do
      repo
      changed = verification
      changed["paths"]["/v3/billing/balance/"]["get"]["x-didit-sdk"] = naming("billing", "top_up")
      changed["paths"]["/v3/billing/top-up/"]["post"]["x-didit-sdk"] = naming("billing", "retrieve_balance")
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(section("Breaking changes")).to include(
        "`billing.top_up` now calls `GET /v3/billing/balance/` instead of `POST /v3/billing/top-up/`",
        "`billing.retrieve_balance` now calls `POST /v3/billing/top-up/` instead of `GET /v3/billing/balance/`"
      )
      expect(File.exist?(openapi("deprecated-operations.json"))).to be(false)
    end
  end

  describe "deprecated-operations.json maintenance" do
    def entry(name, key, remove_in)
      resource, method = name.split(/\.(?=[^.]+\z)/)
      {
        "reason" => "removed", "operation_key" => key, "x-didit-sdk" => naming(resource, method), "since" => "2026-09-01",
        "deprecated_since" => "0.1.0", "remove_in" => remove_in, "note" => "Removed.",
        "operation" => { "summary" => "Old", "responses" => ok({ "type" => "object" }) }
      }
    end

    it "deletes an entry whose operation came back upstream" do
      repo(deprecated: { "description" => "kept", "methods" => {
             "billing.refund" => entry("billing.refund", "POST /v3/billing/refund/", "0.2.0")
           } })
      changed = verification
      changed["paths"]["/v3/billing/refund/"] = {
        "post" => op("Refund", responses: ok({ "type" => "object" }), naming: naming("billing", "refund"))
      }
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(File.read(openapi("deprecated-operations.json"), encoding: "UTF-8"))
        .to eq(JSON.pretty_generate({ "description" => "kept", "methods" => {} }))
      expect(section("Deprecations")).to include("`billing.refund`: provided again by `POST /v3/billing/refund/`")
      expect(section("Operations")).not_to include("POST /v3/billing/refund/")
      expect(generated("lib/didit/resources/billing.rb")).to include("def refund(")
    end

    it "deletes entries whose remove_in version has shipped" do
      repo(version: "0.2.0", deprecated: { "description" => "kept", "methods" => {
             "billing.old_report" => entry("billing.old_report", "GET /v3/billing/report/", "0.2.0"),
             "billing.older" => entry("billing.older", "GET /v3/billing/older/", "0.1.0"),
             "billing.recent" => entry("billing.recent", "GET /v3/billing/recent/", "0.3.0")
           } })
      changed = verification
      changed["info"]["description"] = "a documentation change"
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(read_json("deprecated-operations.json")["methods"].keys).to eq(["billing.recent"])
      expired = section("Deprecations")
      expect(expired).to include("### Expired (2)", "`billing.old_report`: deleted; deprecated since 0.1.0 and " \
                                                    "kept through version 0.2.0 (the SDK is at 0.2.0)")
      expect(section("Breaking changes")).to include("`billing.older` is deleted")
      billing = generated("lib/didit/resources/billing.rb")
      expect(billing).to include("def recent(")
      expect(billing).not_to include("def old_report(")
    end
  end

  describe "a download that is not an OpenAPI 3 document" do
    [
      ["an HTML page", "<html>maintenance</html>"],
      ["a JSON error", '{"message": "maintenance"}'],
      ["a document without paths", '{"openapi": "3.1.0", "paths": {}}'],
      ["Swagger 2", '{"swagger": "2.0", "openapi": "2.0", "paths": {"/x": {}}}'],
      ["a JSON array", "[]"],
      ["bytes that are not UTF-8", "{\"openapi\": \"3.0.0\", \"x\": \"\xFF\"}".b]
    ].each do |label, bytes|
      it "is refused for #{label}, exit 1 and nothing written" do
        repo
        upstream(account: bytes)
        before = snapshot
        expect(sync).to eq(1)
        expect(err.string).to include("account.json", "Nothing was written.")
        expect(snapshot).to eq(before)
        expect(github_output).to be_nil
      end
    end
  end

  describe "a new operation without SDK naming" do
    it "writes the documents and the summary, explains the fix and exits 2" do
      repo
      changed = verification
      changed["paths"]["/v3/organization/{organization_id}/application/{application_id}/cases/{case_uuid}/notes/"] =
        { "get" => op("List case notes", responses: ok({ "type" => "object" })) }
      upstream(verification: changed)
      expect(sync).to eq(2)
      expect(File.binread(openapi("verification.json"))).to eq(JSON.generate(changed))
      expect(File.read(openapi("SOURCE.json"), encoding: "UTF-8")).to include(fetched_at)
      expect(generated("lib/didit/resources/billing.rb")).to be_nil
      expect(err.string).to include("the generator failed", "These operations have no SDK naming")
      action = section("Action needed")
      key = "GET /v3/organization/{organization_id}/application/{application_id}/cases/{case_uuid}/notes/"
      expect(action).to include("#{key} (operationId list_case_notes)", "```json")
      suggestion = JSON.parse(action[/```json\n(.*?)```/m, 1])
      expect(suggestion).to eq(key => { "auth" => "api_key", "method" => "list", "resource" => "cases.notes",
                                        "scope" => "application", "server" => true })
      expect(section("Operations")).to include("`#{key}`: **no SDK naming**")
      expect(summary).to start_with("chore(spec): sync API spec 2026-10-18\n\n")
      expect(github_output).to eq(["changed=true", "breaking=false", "date=2026-10-18"])
    end

    it "suggests the old naming for an operation that lost it upstream" do
      repo(overlay: base_overlay.reject { |k, _| k == "POST /v3/session/" })
      File.write(openapi("verification.json"), JSON.generate(verification.tap do |doc|
        doc["paths"]["/v3/session/"]["post"]["x-didit-sdk"] = naming("sessions", "create")
      end))
      upstream(verification: verification)
      expect(sync).to eq(2)
      expect(section("Breaking changes")).to include("`sessions.create` (`POST /v3/session/`) has no SDK naming any " \
                                                     "more")
      suggestion = JSON.parse(section("Action needed")[/```json\n(.*?)```/m, 1])
      expect(suggestion).to eq("POST /v3/session/" => naming("sessions", "create"))
    end
  end

  describe "breaking change detection" do
    def breaking
      section("Breaking changes")
    end

    it "lists every change that breaks code written against the SDK" do
      repo
      changed = verification
      request = changed["components"]["schemas"]["SessionRequest"]
      request["properties"].delete("vendor_data")
      request["required"] << "callback"
      request["properties"]["language"]["enum"] = %w[en es]
      request["properties"]["title"] = { "type" => "integer" }
      response = changed["components"]["schemas"]["Session"]
      response["properties"].delete("url")
      response["properties"]["status"]["enum"].delete("In Progress")
      response["properties"]["title"] = { "type" => "integer" }
      changed["paths"]["/v3/billing/top-up/"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"]["currency"] =
        { "type" => "string" }
      changed["paths"]["/v3/billing/top-up/"]["post"]["requestBody"]["content"]["application/json"]["schema"]["required"] <<
        "currency"
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(breaking).to include(
        "`sessions.create` (`POST /v3/session/`): request body `vendor_data`: field removed",
        "`sessions.create` (`POST /v3/session/`): request body `callback`: now required",
        "`sessions.create` (`POST /v3/session/`): request body `language`: enum value `fr` removed",
        "`sessions.create` (`POST /v3/session/`): request body `title`: type changed from string to integer",
        "`sessions.create` (`POST /v3/session/`): response 201 `url`: field removed",
        "`sessions.create` (`POST /v3/session/`): response 201 `title`: type changed from string to integer",
        "`sessions.retrieve_decision` (`GET /v3/session/{sessionId}/decision/`): response 200 `title`: type " \
        "changed from string to integer",
        "`billing.top_up` (`POST /v3/billing/top-up/`): request body `currency`: new required field"
      )
      # Response enums are open (docs/DESIGN.md section 5.1): a removed value breaks nobody.
      expect(breaking).not_to include("`In Progress` removed")
      expect(section("Operations")).to include("response 201 `status`: enum value `In Progress` removed\n")
      expect(commit_message).to include("BREAKING CHANGE:", "request body `title`: type changed")
    end

    it "notices documentation-only changes, also of properties named like keywords" do
      repo
      changed = verification
      changed["components"]["schemas"]["Session"]["properties"]["title"]["description"] = "The title."
      changed["components"]["schemas"]["Session"]["description"] = "A session."
      upstream(verification: changed)
      expect(sync).to eq(0)
      expect(section("Breaking changes")).to include("None detected.")
      expect(section("Operations")).to include("`POST /v3/session/` (`sessions.create`): documentation only")
      expect(section("Schemas")).to include("`Session` changed (verification.json), documentation only")
    end
  end

  describe "the summary limits" do
    it "lists at most 100 items per section" do
      repo
      changed = verification
      120.times do |i|
        changed["paths"]["/v3/things/#{i}/"] = {
          "get" => op("Thing #{i}", responses: ok({ "type" => "object" }), naming: naming("things", "get_#{i}"))
        }
      end
      upstream(verification: changed)
      expect(sync).to eq(0)
      added = section("Operations")
      expect(added).to include("### Added (120)", "- ... and 20 more")
      expect(added.scan(/^- `GET \/v3\/things/).size).to eq(100)
    end

    it "caps the summary at 60 000 characters with a truncation note" do
      report = DiditCodegen::Sync::Report.new(date)
      report.add_file("verification.json", "https://example.com/a.json", "a" * 64, "b" * 64)
      report.action_needed = ["x" * 70_000, {}]
      %i[breaking added removed renamed moved changed schemas naming].each do |list|
        100.times { |i| report.send(list) << "`item #{i}` #{'y' * 300}" }
      end
      text = report.summary
      expect(text.length).to be <= 60_000
      expect(text).to start_with("chore(spec): sync API spec 2026-10-18\n\n")
      expect(text).to end_with("_The summary was truncated at 60000 characters; the spec sync workflow log has " \
                               "all of it._\n")
      expect(text.scan(/^```/).size).to be_even
      expect(report.summary(limit: false).length).to be > 60_000
    end
  end

  describe "the command line" do
    it "runs codegen/spec_sync.rb as a script" do
      repo
      upstream
      script = File.expand_path("../spec_sync.rb", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, "--root", root, "--from-dir", upstream_dir)
      expect([stdout, stderr, status.exitstatus]).to eq(["No upstream change\n", "", 0])
    end

    it "accepts the upstream file names in --from-dir" do
      repo
      FileUtils.mkdir_p(upstream_dir)
      changed = verification
      changed["info"]["version"] = "2"
      File.write(File.join(upstream_dir, "openapi-25.json"), JSON.generate(changed))
      FileUtils.cp(openapi("account.json"), File.join(upstream_dir, "openapi-auth.json"))
      expect(sync).to eq(0)
      expect(File.read(openapi("verification.json"))).to eq(JSON.generate(changed))
    end

    it "rejects a bad --date and unknown options" do
      repo
      upstream
      expect(sync("--date", "18/10/2026")).to eq(1)
      expect(err.string).to include("--date 18/10/2026", "usage: ruby codegen/spec_sync.rb")
      expect(sync("--bogus")).to eq(1)
      expect(err.string).to include("--bogus")
    end

    it "downloads both documents when --from-dir is not given" do
      repo
      changed = JSON.generate(verification.merge("info" => { "title" => "t", "version" => "9" }))
      downloader = instance_double(DiditCodegen::Sync::Downloader)
      allow(downloader).to receive(:fetch).with("https://docs.didit.me/openapi-25.json").and_return(changed.b)
      allow(downloader).to receive(:fetch).with("https://docs.didit.me/openapi-auth.json")
                                          .and_return(File.binread(openapi("account.json")))
      expect(sync(downloader: downloader)).to eq(0)
      expect(File.read(openapi("verification.json"))).to eq(changed)
    end
  end

  describe DiditCodegen::Sync::Downloader do
    let(:url) { "https://docs.didit.me/openapi-25.json" }

    it "sends the User-Agent and returns the body" do
      stub = stub_request(:get, url).with(headers: { "User-Agent" => "didit-sdk-ruby-spec-sync" })
                                    .to_return(status: 200, body: '{"openapi": "3.0.0"}')
      expect(described_class.new.fetch(url)).to eq('{"openapi": "3.0.0"}'.b)
      expect(stub).to have_been_requested
    end

    it "follows up to 3 redirects on the same host" do
      stub_request(:get, url).to_return(status: 301, headers: { "Location" => "/a.json" })
      stub_request(:get, "https://docs.didit.me/a.json").to_return(status: 302, headers: { "Location" => "/b.json" })
      stub_request(:get, "https://docs.didit.me/b.json")
        .to_return(status: 307, headers: { "Location" => "https://docs.didit.me/c.json" })
      stub_request(:get, "https://docs.didit.me/c.json").to_return(status: 200, body: "{}")
      expect(described_class.new.fetch(url)).to eq("{}")
    end

    it "refuses a fourth redirect" do
      4.times do |i|
        stub_request(:get, i.zero? ? url : "https://docs.didit.me/#{i}.json")
          .to_return(status: 302, headers: { "Location" => "/#{i + 1}.json" })
      end
      expect { described_class.new.fetch(url) }
        .to raise_error(DiditCodegen::Sync::InputError, /more than 3 redirects/)
    end

    it "refuses a redirect to another host or to http" do
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "https://evil.example/x.json" })
      expect { described_class.new.fetch(url) }.to raise_error(DiditCodegen::Sync::InputError, /another host/)
      stub_request(:get, url).to_return(status: 302, headers: { "Location" => "http://docs.didit.me/x.json" })
      expect { described_class.new.fetch(url) }.to raise_error(DiditCodegen::Sync::InputError, /only https/)
    end

    it "refuses http URLs, error statuses, network errors and oversized bodies" do
      expect { described_class.new.fetch("http://docs.didit.me/x.json") }
        .to raise_error(DiditCodegen::Sync::InputError, /only https/)
      stub_request(:get, url).to_return(status: 503)
      expect { described_class.new.fetch(url) }.to raise_error(DiditCodegen::Sync::InputError, /HTTP 503/)
      stub_request(:get, url).to_timeout
      expect { described_class.new.fetch(url) }.to raise_error(DiditCodegen::Sync::InputError, /GET #{url}/)
      stub_request(:get, url).to_return(status: 200, body: "x" * 11)
      expect { described_class.new(max_bytes: 10).fetch(url) }
        .to raise_error(DiditCodegen::Sync::InputError, /larger than 10 bytes/)
    end
  end

  describe DiditCodegen::Sync::JsonText do
    it "writes JSON in the layout of the original" do
      data = { "a" => { "b" => [1, "é"] } }
      expect(described_class.dump_like(%({\n "x": 1\n}), data)).to eq(JSON.pretty_generate(data, indent: " "))
      expect(described_class.dump_like(%({\n  "x": 1\n}\n), data)).to eq("#{JSON.pretty_generate(data)}\n")
      expect(described_class.dump_like(%({\n "x": "\\u00e9"\n}), data)).to include('"\u00e9"')
      expect(described_class.dump_like(nil, data)).to eq(JSON.pretty_generate(data, indent: " "))
    end
  end
end
