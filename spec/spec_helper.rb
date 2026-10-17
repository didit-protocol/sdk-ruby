# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter %r{\A/spec/}
    add_filter %r{\A/codegen/}
    # Coverage is measured on the hand-written core; the generated layer is
    # covered by one generated test per operation.
    add_filter %r{\A/lib/didit/resources}
    add_filter %r{\A/lib/didit/types}
    minimum_coverage line: Integer(ENV.fetch("COVERAGE_MIN", "90"))
  end
end

require "didit"
require "webmock/rspec"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Live smoke tests only run when DIDIT_SANDBOX_API_KEY is set.
  config.filter_run_excluding live: true unless ENV["DIDIT_SANDBOX_API_KEY"]

  # The environment never leaks into unit tests.
  config.around do |example|
    saved = ENV.to_h.select { |k, _| k.start_with?("DIDIT_") }
    saved.each_key { |k| ENV.delete(k) } unless example.metadata[:live]
    example.run
  ensure
    ENV.each_key.select { |k| k.start_with?("DIDIT_") }.each { |k| ENV.delete(k) }
    saved&.each { |k, v| ENV[k] = v }
  end
end
