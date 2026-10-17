# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = "spec/**/*_spec.rb"
end

namespace :codegen do
  desc "Run the generator's own tests"
  RSpec::Core::RakeTask.new(:spec) do |t|
    t.pattern = "codegen/spec/**/*_spec.rb"
    t.rspec_opts = "--default-path codegen/spec --require ./codegen/spec/spec_helper"
  end
end

desc "Regenerate lib/didit/resources*, lib/didit/types*, their signatures and spec/generated from openapi/"
task :generate do
  ruby "codegen/generate.rb"
end

namespace :generate do
  desc "Fail when the committed generated code differs from what openapi/ produces"
  task :check do
    ruby "codegen/generate.rb", "--check"
  end
end

desc "Download the upstream API spec, regenerate and summarise the changes (see CONTRIBUTING.md)"
task :spec_sync do
  ruby "codegen/spec_sync.rb"
end

desc "RuboCop"
task :rubocop do
  sh "rubocop"
end

desc "Type check with Steep (needs Ruby 3.3 or newer)"
task :steep do
  sh "steep check"
end

desc "Build the gem into pkg/ (never publishes)"
task :build do
  mkdir_p "pkg"
  sh "gem build didit-sdk.gemspec --output pkg/didit-sdk-#{Gem::Specification.load("didit-sdk.gemspec").version}.gem"
end

task default: %i[generate:check spec codegen:spec rubocop]
