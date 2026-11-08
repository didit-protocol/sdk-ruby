# frozen_string_literal: true

module Didit
  # Implementation details. Nothing under this module is public API.
  # @api private
  module Internal
    autoload :Config, "didit/internal/config"
    autoload :Errors, "didit/internal/errors"
    autoload :Log, "didit/internal/log"
    autoload :Multipart, "didit/internal/multipart"
    autoload :Request, "didit/internal/request"
    autoload :Transport, "didit/internal/transport"
    autoload :Util, "didit/internal/util"
  end
end
