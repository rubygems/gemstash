# frozen_string_literal: true

require "yaml"
require "erb"

module Gemstash
  # :nodoc:
  class Configuration
    DEFAULTS = {
      cache_type: "memory",
      base_path: File.expand_path("~/.gemstash"),
      db_adapter: "sqlite3",
      bind: "tcp://0.0.0.0:9292",
      rubygems_url: "https://rubygems.org",
      ignore_gemfile_source: false,
      allowed_upstreams: [],
      allowed_redirects: [],
      protected_fetch: false,
      fetch_timeout: 20,
      open_timeout: 2,
      # Actual default for db_connection_options is dynamic based on the adapter
      db_connection_options: {},
      puma_threads: 16,
      puma_workers: 1,
      cache_expiration: 30 * 60,
      cache_max_size: 500
    }.freeze

    DEFAULT_FILE = File.expand_path("~/.gemstash/config.yml").freeze

    # A scheme other than a lowercase http or https. Gemstash::Upstream would
    # read such an entry as a host name and put https:// in front of it.
    UNSUPPORTED_SCHEME = %r{\A(?!https?://)[A-Za-z][A-Za-z0-9+.-]*://}

    # An http or https scheme without the // after it. Gemstash::Upstream would
    # read "https:user:pass@host" as user "https" and "https:/host" as host "https".
    SCHEME_WITHOUT_SLASHES = %r{\Ahttps?:(?!//)}i

    # This error is thrown when a config file is explicitly specified that
    # doesn't exist.
    class MissingFileError < StandardError
      def initialize(file)
        super("Missing config file: #{file}")
      end
    end

    # This error is thrown when :allowed_upstreams or :allowed_redirects has an
    # entry that cannot be used. It gives the position of the entry and never
    # its value, because the value can contain credentials.
    class InvalidAllowedUpstreamError < StandardError
      def initialize(key, position, problem)
        accepted = key == :allowed_upstreams ? "\"*\" or an http(s) gem source URL" : "an http(s) URL"
        super("Invalid :#{key} entry #{position} (#{problem}). Each entry must be #{accepted}.")
      end
    end

    def initialize(file: nil, config: nil, validate: true)
      if config
        @config = DEFAULTS.merge(config).freeze
        validate_allowed_upstreams if validate
        return
      end

      raise MissingFileError, file if file && !File.exist?(file)

      file ||= default_file

      if File.exist?(file)
        @config = parse_config(file)
        @config = DEFAULTS.merge(@config)
        @config.freeze
      else
        @config = DEFAULTS
      end

      validate_allowed_upstreams if validate
    end

    def default?(key)
      @config[key] == DEFAULTS[key]
    end

    def [](key)
      @config[key]
    end

    def keys
      @config.keys
    end

    # @return [Hash] Sequel connection configuration hash
    def database_connection_config
      case self[:db_adapter]
      when "sqlite3"
        { max_connections: 1 }.merge(self[:db_connection_options])
      when "postgres", "mysql", "mysql2"
        { max_connections: (self[:puma_workers] * self[:puma_threads]) + 1 }.merge(self[:db_connection_options])
      else
        raise "Unsupported DB adapter: '#{self[:db_adapter]}'"
      end
    end

  private

    def default_file
      # Support the config file being specified via environment variable
      gemstash_config = ENV["GEMSTASH_CONFIG"]
      return gemstash_config if gemstash_config

      # If no environment variable is used, fall back to the normal defaults
      File.exist?("#{DEFAULT_FILE}.erb") ? "#{DEFAULT_FILE}.erb" : DEFAULT_FILE
    end

    def parse_config(file)
      if file.end_with?(".erb")
        YAML.load(ERB.new(File.read(file)).result) || {}
      else
        YAML.load_file(file) || {}
      end
    end

    # Entries are checked when the configuration is loaded, so that a typo
    # stops Gemstash from starting instead of failing requests later on.
    def validate_allowed_upstreams
      %i[allowed_upstreams allowed_redirects].each do |key|
        Array(self[key]).each_with_index do |entry, index|
          problem = allowed_upstream_problem(entry, wildcard: key == :allowed_upstreams)
          raise InvalidAllowedUpstreamError.new(key, index + 1, problem) if problem
        end
      end
    end

    def allowed_upstream_problem(entry, wildcard:)
      return if entry == "*" && wildcard
      return "wildcard is not supported" if entry == "*"
      return "not a string" unless entry.is_a?(String)
      return "empty" if entry.strip.empty?
      return "scheme is not http:// or https://" if entry.match?(UNSUPPORTED_SCHEME)
      return "scheme is not followed by //" if entry.match?(SCHEME_WITHOUT_SLASHES)

      begin
        "no host" if Gemstash::Upstream.new(entry).host.to_s.empty?
      rescue URI::InvalidURIError, RuntimeError
        # The parser's message repeats the entry, so it is not passed on.
        "not a valid URL"
      end
    end
  end
end
