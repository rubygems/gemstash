# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

# Workaround: some rubocop versions prioritize ~/.config/rubocop/config.yml
# over the project's .rubocop.yml, so we explicitly specify the config file.
RuboCop::RakeTask.new do |t|
  t.options = %w[-c .rubocop.yml]
end

desc "Run specs"
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = %w[--color]
end

task spec: :rubocop
task default: :spec

desc "Update ChangeLog based on commits in main"
task :changelog do
  Changelog.new.run
end

desc "Generate markdown, man, text, and html documentation"
task :doc do
  Doc.new.run
end

task build: :doc

Rake::Task["release:guard_clean"].clear
