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

  autoload :Authentication, File.expand_path("didit/authentication", __dir__)
  autoload :Client, File.expand_path("didit/client", __dir__)
  autoload :FilePart, File.expand_path("didit/file_part", __dir__)
  autoload :Internal, File.expand_path("didit/internal", __dir__)
  autoload :Model, File.expand_path("didit/model", __dir__)
  autoload :Page, File.expand_path("didit/page", __dir__)
  autoload :RawResponse, File.expand_path("didit/raw_response", __dir__)
  autoload :Resource, File.expand_path("didit/resource", __dir__)
  autoload :Resources, File.expand_path("didit/resources", __dir__)
  autoload :Types, File.expand_path("didit/types", __dir__)
  autoload :Webhooks, File.expand_path("didit/webhooks", __dir__)
end
