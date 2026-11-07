# frozen_string_literal: true

# Syncs openapi/ with the published API contract (docs/DESIGN.md section 3.1).
#
#   ruby codegen/spec_sync.rb [--from-dir DIR] [--summary FILE] [--commit-message FILE] [--date YYYY-MM-DD]
#
# Downloads https://docs.didit.me/openapi-25.json and openapi-auth.json (or reads
# verification.json and account.json from --from-dir). Anything that is not an OpenAPI 3
# document with paths is refused and nothing is written (exit 1). When neither changed it
# prints "No upstream change" and exits 0. Otherwise it writes them to openapi/ byte for
# byte, records them in openapi/SOURCE.json, deletes overlay.json entries that upstream now
# names, keeps removed or renamed server methods as deprecated for one minor version in
# openapi/deprecated-operations.json, regenerates the SDK and writes the pull request
# summary (first line: the title) and the commit message. When the generator fails (for
# example on a new operation without SDK naming) the files are still written, the summary
# gets an "Action needed" section and the exit code is 2. With $GITHUB_OUTPUT set it
# appends changed=, breaking= and date= to it.

require_relative "lib/didit_codegen"
require_relative "lib/didit_codegen/sync"

exit DiditCodegen::Sync::CLI.new(root: File.expand_path("..", __dir__)).run(ARGV)
