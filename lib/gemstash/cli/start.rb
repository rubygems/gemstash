# frozen_string_literal: true

require "gemstash"
require "puma/cli"

module Gemstash
  class CLI
    # This implements the command line start task to start the Gemstash server:
    #  $ gemstash start
    class Start < Gemstash::CLI::Base
      def run
        prepare
        setup_logging
        store_daemonized
        @cli.say("Starting gemstash!", :green)
        Puma::CLI.new(args, Gemstash::Logging::StreamLogger.puma_events).run
      end

    private

      def setup_logging
        return unless daemonize?

        Gemstash::Logging.setup_logger(gemstash_env.log_file)
      end

      def store_daemonized
        Gemstash::Env.daemonized = daemonize?
      end

      def daemonize?
        @cli.options[:daemonize]
      end

      def args
        puma_args + pidfile_args + daemonize_args
      end

      def puma_args
        [
          "--config", puma_config,
          "--workers", puma_workers,
          "--threads", puma_threads
        ]
      end

      def puma_workers
        gemstash_env.config[:puma_workers] ? gemstash_env.config[:puma_workers].to_s : "0"
      end

      def puma_threads
        gemstash_env.config[:puma_threads] ? gemstash_env.config[:puma_threads].to_s : "0"
      end

      def puma_config
        File.expand_path("../puma.rb", __dir__)
      end

      def daemonize_args
        if daemonize?
          ["--daemon"]
        else
          []
        end
      end
    end
  end
end
