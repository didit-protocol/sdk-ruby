# frozen_string_literal: true

module Didit
  # Base class of the generated resources (+didit.sessions+, +didit.sessions.imports+, ...).
  class Resource
    # @param client [Didit::Client]
    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end
  end
end
