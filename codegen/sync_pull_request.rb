# frozen_string_literal: true

# Updates the open spec sync pull request when a sync is pushed on top of commits from people
# (docs/DESIGN.md section 3.1).
#
#   ruby codegen/sync_pull_request.rb --previous PR.json --body BODY.md --out DIR
#
# PR.json is what `gh pr view --json title,body` prints; BODY.md is the description this sync
# would have on its own. Writes DIR/title.txt and DIR/body.md, the pull request title and
# description, whose "Breaking changes" list and release block now also carry this sync's
# entries (feat wins over chore), and DIR/comment.md, this sync's summary. Exit 1 when an
# input is unusable.

require_relative "lib/didit_codegen"
require_relative "lib/didit_codegen/sync"

exit DiditCodegen::Sync::PullRequest.main(ARGV)
