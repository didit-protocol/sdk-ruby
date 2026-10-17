# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "didit_codegen"
require "json"
require "tmpdir"
require "fileutils"

# Fixture repositories for the generator and spec sync tests. They never read the live
# openapi/ files, so a spec sync that changes those files cannot break these tests.
module CodegenFixtures
  module_function

  def operation(summary, naming, extra = {})
    { "summary" => summary, "operationId" => naming.values_at("resource", "method").join("_"),
      "x-didit-sdk" => naming }.merge(extra)
  end

  # Writes a minimal repository (openapi/ and lib/didit/version.rb) into +dir+.
  def write_repo(dir, verification:, account: nil, overlay: {}, deprecated: nil, version: "0.1.0")
    FileUtils.mkdir_p(File.join(dir, "openapi"))
    FileUtils.mkdir_p(File.join(dir, "lib", "didit"))
    account ||= { "openapi" => "3.0.0", "info" => { "title" => "a", "version" => "1" }, "paths" => {} }
    write_json(File.join(dir, "openapi", "verification.json"), verification)
    write_json(File.join(dir, "openapi", "account.json"), account)
    write_json(File.join(dir, "openapi", "overlay.json"), { "description" => "test", "version" => 1, "operations" => overlay })
    write_json(File.join(dir, "openapi", "deprecated-operations.json"), deprecated) if deprecated
    File.write(File.join(dir, "lib", "didit", "version.rb"),
               "# frozen_string_literal: true\n\nmodule Didit\n  VERSION = \"#{version}\"\nend\n")
    dir
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value))
  end

  def document(paths, schemas = {})
    { "openapi" => "3.0.0", "info" => { "title" => "t", "version" => "1" }, "paths" => paths,
      "components" => { "schemas" => schemas } }
  end
end

RSpec.configure do |config|
  config.include CodegenFixtures
  config.disable_monkey_patching!
end
