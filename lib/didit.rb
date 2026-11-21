# frozen_string_literal: true

require_relative "didit/version"
require_relative "didit/errors"

# The official Didit Ruby library.
#
#   didit = Didit::Client.new # reads DIDIT_API_KEY
#   session = didit.sessions.create(workflow_id: "...", vendor_data: "user-42")
#
# See https://docs.didit.me and docs/DESIGN.md.
module Didit
  # The value of a keyword argument the caller did not pass. Such arguments are
  # left out of the request; +nil+ sends JSON +null+.
  OMIT = Object.new.tap do |omit|
    def omit.inspect = "Didit::OMIT"
    def omit.to_s = "Didit::OMIT"
  end.freeze

  autoload :Authentication, "didit/authentication"
  autoload :Client, "didit/client"
  autoload :FilePart, "didit/file_part"
  autoload :Internal, "didit/internal"
  autoload :Model, "didit/model"
  autoload :Page, "didit/page"
  autoload :RawResponse, "didit/raw_response"
  autoload :Resource, "didit/resource"
  autoload :Resources, "didit/resources"
  autoload :Types, "didit/types"
  autoload :Webhooks, "didit/webhooks"
end
