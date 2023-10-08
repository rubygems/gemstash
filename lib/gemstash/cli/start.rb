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
        @cli.say("Starting gemstash!", :green)
        Puma::CLI.new(args, Gemstash::Logging::StreamLogger.puma_events).run
      end

    private

      def puma_config
        File.expand_path("../puma.rb", __dir__)
      end

      def args
        config_args + pidfile_args
      end

      def config_args
        ["--config", puma_config]
      end
    end
  end
end
