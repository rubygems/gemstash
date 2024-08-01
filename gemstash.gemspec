#  frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "gemstash/version"

Gem::Specification.new do |spec|
  spec.name          = "gemstash"
  spec.version       = Gemstash::VERSION
  spec.authors       = ["Andre Arko"]
  spec.email         = ["andre@arko.net"]
  spec.platform      = "java" if RUBY_PLATFORM == "java"

  spec.summary       = "A place to stash gems you'll need"
  spec.description   = "Gemstash acts as a local RubyGems server, caching \
copies of gems from RubyGems.org automatically, and eventually letting \
you push your own private gems as well."
  spec.homepage      = "https://github.com/rubygems/gemstash"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").select do |f|
    f.match(/^(lib|exe|CHANGELOG|CODE_OF_CONDUCT|LICENSE)/)
  end
  # we don't check in man pages, but we need to ship them because
  # we use them to generate the long-form help for each command.
  spec.files += Dir.glob("lib/gemstash/man/**/*")

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) {|f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_runtime_dependency "activesupport", ">= 4.2", "< 8"
  spec.add_runtime_dependency "compact_index", "~> 0.15.0"
  spec.add_runtime_dependency "dalli", ">= 3.2.3", "< 4"
  spec.add_runtime_dependency "faraday", ">= 1", "< 3"
  spec.add_runtime_dependency "faraday_middleware", "~> 1.0"
  spec.add_runtime_dependency "lru_redux", "~> 1.1"
  spec.add_runtime_dependency "psych", ">= 3.2.1"
  spec.add_runtime_dependency "puma", "~> 6.1"
  spec.add_runtime_dependency "sequel", "~> 5.0"
  spec.add_runtime_dependency "server_health_check-rack", "~> 0.1"
  spec.add_runtime_dependency "sinatra", ">= 1.4", "< 5.0"
  spec.add_runtime_dependency "terminal-table", "~> 3.0"
  spec.add_runtime_dependency "thor", "~> 1.0"

  # Use Redis instead of memcached
  # spec.add_runtime_dependency "redis", "~> 3.3"
  # Run Gemstash with the mysql adapter
  # spec.add_runtime_dependency "mysql", "~> 2.9"
  # Run Gemstash with the mysql2 adapter
  # spec.add_runtime_dependency "mysql2", "~> 0.4"

  if RUBY_PLATFORM == "java"
    spec.add_runtime_dependency "jdbc-sqlite3", "~> 3.8"
  else
    # SQLite 3.44+ is required for string_agg support
    spec.add_runtime_dependency "sqlite3", ">= 1.68", "< 3.0"
  end
end
