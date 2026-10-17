# frozen_string_literal: true

require_relative "lib/didit/version"

Gem::Specification.new do |spec|
  spec.name = "didit-sdk"
  spec.version = Didit::VERSION
  spec.authors = ["Didit"]
  spec.email = ["support@didit.me"]

  spec.summary = "The official Didit Ruby library."
  spec.description = <<~TEXT.tr("\n", " ").strip
    The official Didit server-side library for Ruby: identity verification (KYC), business verification (KYB),
    AML screening, liveness and face match, transaction monitoring, Travel Rule, webhooks and Didit
    customer Authentication.
  TEXT
  spec.homepage = "https://didit.me"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => "https://didit.me",
    "documentation_uri" => "https://docs.didit.me",
    "source_code_uri" => "https://github.com/didit-protocol/sdk-ruby",
    "changelog_uri" => "https://github.com/didit-protocol/sdk-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/didit-protocol/sdk-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # Only the Authentication module (Didit::Authentication) loads it.
  spec.add_dependency "jwt", ">= 2.7", "< 4"
end
