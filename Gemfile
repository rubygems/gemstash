# frozen_string_literal: true

source "https://rubygems.org"

gemspec
gem "aruba", ">= 0.14"
gem "citrus", "~> 3.0"
gem "octokit", "~> 4.2"
gem "pandoc_object_filters", "~> 0.2"
gem "rack-test", "~> 1.1"
gem "rake", "~> 12.3"
gem "redis", "~> 3.3"
gem "rspec", "~> 3.3"

platform :jruby do
  gem "psych", "~> 4.0.6"
end

group :linting do
  gem "rubocop", "= 0.67.2"
  gem "rubocop-performance", "~> 1.1.0"
end

gem "webrick" if RUBY_VERSION >= "3"
