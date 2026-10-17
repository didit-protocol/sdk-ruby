# frozen_string_literal: true

module Didit
  # Implementation details. Nothing under this module is public API.
  # @api private
  module Internal
    autoload :Config, File.expand_path("internal/config", __dir__)
    autoload :Errors, File.expand_path("internal/errors", __dir__)
    autoload :Log, File.expand_path("internal/log", __dir__)
    autoload :Multipart, File.expand_path("internal/multipart", __dir__)
    autoload :Request, File.expand_path("internal/request", __dir__)
    autoload :Transport, File.expand_path("internal/transport", __dir__)
    autoload :Util, File.expand_path("internal/util", __dir__)
  end
end
