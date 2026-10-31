# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.2"

# CI sets JWT_VERSION (job jwt-2) to test Authentication with jwt 2.x; the gemspec allows ">= 2.7, < 4".
gem "jwt", ENV["JWT_VERSION"] if ENV["JWT_VERSION"]

group :test do
  gem "rack", "~> 3.1"
  gem "rspec", "~> 3.13"
  gem "simplecov", "~> 1.3", require: false
  gem "webmock", "~> 3.25"
end

group :lint do
  gem "rubocop", "~> 1.81", require: false
  gem "rubocop-performance", "~> 1.26", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "rubocop-rspec", "~> 3.7", require: false
end

# Steep and RBS 4 need Ruby 3.3 or newer; the type check runs on the newest Ruby only.
group :typecheck do
  gem "steep", "~> 2.1", require: false if RUBY_VERSION >= "3.3"
end
