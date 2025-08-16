# frozen_string_literal: true

require "logger"

begin
  require "puma/detect"
  require "puma/log_writer" # Puma 6
rescue LoadError
  require "puma/events"
end

module Gemstash
  # :nodoc:
  module Logging
    extend Gemstash::Env::Helper

    LEVELS = {
      debug: Logger::DEBUG,
      info: Logger::INFO,
      warn: Logger::WARN,
      error: Logger::ERROR,
      fatal: Logger::FATAL
    }.freeze

    def log
      Gemstash::Logging.logger
    end

    def log_error(message, error, level: :error)
      log.add(LEVELS[level]) do
        "#{message} - #{error.message} (#{error.class})\n  #{error.backtrace.join("\n  ")}"
      end
    end

    def self.setup_logger(logfile)
      @logger = Logger.new(logfile, 2, 10_485_760)
      @logger.level = Logger::INFO
      @logger.datetime_format = "%d/%b/%Y:%H:%M:%S %z"
      @logger.formatter = proc do |severity, datetime, _progname, msg|
        if msg.end_with?("\n")
          "[#{datetime}] - #{severity} - #{msg}"
        else
          "[#{datetime}] - #{severity} - #{msg}\n"
        end
      end
      @logger
    end

    def self.logger
      @logger ||= setup_logger(gemstash_env.log_file)
    end

    def self.reset
      @logger.close if @logger
      @logger = nil
    end

    # Rack middleware to set the Rack logger to the Gemstash logger.
    class RackMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        env["rack.logger"] = Gemstash::Logging.logger
        env["rack.errors"] = Gemstash::Env.current.log_file
        @app.call(env)
      end
    end

    # Logger that looks like a stream, for Puma and Rack to log to.
    class StreamLogger
      def self.puma_events
        # Puma 6 removed logging from Events and placed it in LogWriter
        klass = Puma.const_defined?(:LogWriter) ? Puma::LogWriter : Puma::Events
        klass.new(for_stdout, for_stderr)
      end

      def self.for_stdout
        new(Logger::INFO)
      end

      def self.for_stderr
        new(Logger::ERROR)
      end

      def initialize(level)
        @level = level
      end

      def flush; end

      def sync=(_value); end

      def sync
        false
      end

      def write(message)
        Gemstash::Logging.logger.add(@level, message)
      end

      def puts(message)
        Gemstash::Logging.logger.add(@level, message)
      end
    end
  end
end
