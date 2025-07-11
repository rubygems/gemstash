# frozen_string_literal: true

require "gemstash"

module Gemstash
  class CLI
    # Base class for common functionality for CLI tasks.
    class Base
      include Gemstash::Env::Helper

      def initialize(cli, *args)
        Gemstash::Env.current = Gemstash::Env.new
        @cli = cli
        @args = args
      end

    private

      def prepare
        check_rubygems_version
        store_config
        check_gemstash_version
      end

      def check_rubygems_version
        unless Gem::Requirement.new(">= 2.4").satisfied_by?(Gem::Version.new(Gem::VERSION))
          @cli.say(@cli.set_color("Rubygems version is too old, " \
                                   "please update rubygems by running: " \
                                   "gem update --system", :red))
        end
      end

      def store_config
        config = Gemstash::Configuration.new(file: @cli.options[:config_file])
        gemstash_env.config = config
      rescue Gemstash::Configuration::MissingFileError => e
        raise Gemstash::CLI::Error.new(@cli, e.message)
      end

      def check_gemstash_version
        version = Gem::Version.new(Gemstash::Storage.metadata[:gemstash_version])
        return if Gem::Requirement.new("<= #{Gemstash::VERSION}").satisfied_by?(Gem::Version.new(version))

        raise Gemstash::CLI::Error.new(@cli, "Gemstash version #{Gemstash::VERSION} does not support version " \
                                             "#{version}.\nIt appears you may have downgraded Gemstash, please " \
                                             "install version #{version} or later.")
      end

      def check_backfills
        # require 'debug'; debugger
        pending_backfills = DB::Backfill.pending
        if pending_backfills.any?
          @cli.say(@cli.set_color("Backfills pending, some features may be disabled", :red))
          pending_backfills.each do |backfill|
            @cli.say(@cli.set_color("- #{backfill.backfill_class}: #{backfill.description}", :red))
          end
          @cli.say(@cli.set_color("Run `gemstash backfill` to fix this.", :red))
        end
      end

      def pidfile_args
        ["--pidfile", gemstash_env.pidfile]
      end
    end
  end
end
