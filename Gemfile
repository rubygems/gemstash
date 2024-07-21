# frozen_string_literal: true

source "https://rubygems.org"

gemspec
gem "aruba"
gem "citrus", "~> 3.0"
gem "octokit"
gem "rack-test", "~> 2.1"
gem "rake", "~> 13.0"
gem "redis", "~> 5.0"
gem "rspec", "~> 3.3"
gem "webrick", "~> 1.6"

platform :jruby do
  gem "jdbc-sqlite3"
  gem "psych"
end

platform :ruby do
  gem "mysql2"
  gem "pg"
  gem "sqlite3"
end

group :linting do
  gem "rubocop", "~> 1.44"
  gem "rubocop-performance", "~> 1.5"
end

group :test do
  gem "gem_server_conformance", "~> 0.1.4"
  gem "mock_redis"
end
