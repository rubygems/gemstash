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
        warn_on_insecure_bind
        @cli.say("Starting gemstash!", :green)
        case @cli.options[:daemonize]
        when false then warn "The --no-daemonize option was removed and has no effect."
        when true then warn "The --daemonize option was removed and has no effect."
        end
        Puma::CLI.new(args, Gemstash::Logging::StreamLogger.puma_events).run
      end

    private

      LOOPBACK_HOSTS = ["127.0.0.1", "::1", "[::1]", "localhost"].freeze

      # Gemstash terminates no TLS itself, so a non-loopback tcp:// bind serves
      # keys and gems in cleartext — warn rather than fail, as TLS may be fronted.
      def warn_on_insecure_bind
        bind = gemstash_env.config[:bind].to_s
        return unless bind.start_with?("tcp://")

        host = bind.delete_prefix("tcp://").split(":", 2).first
        return if LOOPBACK_HOSTS.include?(host)

        message = "Warning: binding to #{bind} serves plaintext HTTP on a non-loopback " \
                  "address. Gemstash has no TLS of its own, so API keys and private gems " \
                  "travel unencrypted. Terminate TLS in front of Gemstash (e.g. a reverse " \
                  "proxy) or bind to loopback."
        @cli.say(@cli.set_color(message, :yellow))
      end

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
