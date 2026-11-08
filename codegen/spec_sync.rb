# frozen_string_literal: true

# Syncs openapi/ with the published API contract (docs/DESIGN.md section 3.1).
#
#   ruby codegen/spec_sync.rb [--from-dir DIR] [--summary FILE] [--release FILE] [--commit-message FILE]
#                             [--date YYYY-MM-DD]
#
# Downloads https://docs.didit.me/openapi-25.json, openapi-auth.json and
# openapi-authentication.json (or reads verification.json, account.json and
# authentication.json from --from-dir). Anything that is not an OpenAPI 3 document with paths
# is refused and nothing is written (exit 1). When none changed it prints "No upstream
# change" and exits 0. Otherwise it writes them to openapi/ byte for byte, records them in
# openapi/SOURCE.json, deletes overlay.json entries that upstream now names, keeps removed or
# renamed server methods as deprecated for one minor version in
# openapi/deprecated-operations.json, regenerates the SDK (authentication.json describes the
# hand-written Didit::Authentication and generates nothing) and writes the pull request
# summary (first line: the title), the "Release" section that ends the pull request body and
# the commit message. The title is "feat(spec): ..." when a caller can observe the change and
# "chore(spec): ..." when only documentation changed; the summary opens with the changes that
# can break typed code, and the Release section holds the block release-please reads instead
# of the commits: the title, then one "api(spec): ..." line per breaking change, every one of
# them (sections 3.1 and 13; when they do not fit the pull request description, the section
# asks to squash with the commit message, which holds them too). What counts follows the
# shared cases of openapi/breaking-vectors.json. Never "!" and never a BREAKING CHANGE footer.
# When the generator fails (for example on a new operation without SDK naming) the files are
# still written, the summary gets an "Action needed" section and the exit code is 2. With
# $GITHUB_OUTPUT set it appends changed=, type= (feat or chore, when changed), breaking= and
# date= to it.

require_relative "lib/didit_codegen"
require_relative "lib/didit_codegen/sync"

exit DiditCodegen::Sync::CLI.new(root: File.expand_path("..", __dir__)).run(ARGV)
