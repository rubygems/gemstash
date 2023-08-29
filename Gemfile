# frozen_string_literal: true

source "https://rubygems.org"

gemspec
gem "aruba", ">= 0.14"
gem "citrus", "~> 3.0"
gem "octokit", "<= 4.22" # 4.22 secretly requires faraday >= 1.0
gem "rack-test", "~> 2.1"
gem "rake", "~> 13.0"
gem "redis", "~> 3.3"
gem "rspec", "~> 3.3"
gem "webrick", "~> 1.6"

platform :jruby do
  gem "psych", "~> 4.0.6"
end

group :linting do
  gem "rubocop", "~> 1.44"
  gem "rubocop-performance", "~> 1.5"
end

group :test do
  gem "mock_redis"
end
