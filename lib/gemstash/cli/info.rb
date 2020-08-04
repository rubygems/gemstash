# frozen_string_literal: true

require "gemstash"
require "puma/control_cli"

module Gemstash
  class CLI
    class Info < Gemstash::CLI::Base
      include Gemstash::Env::Helper
      def run
        prepare
        list_config
      end

    private

      def list_config
        @config = parse_config(config_file)
        @config = Gemstash::Configuration::DEFAULTS.merge(@config)
        @config.map do |key, _value|
          @cli.say "#{key}: #{gemstash_env.config[key]}"
        end
      end

      def config_file
        @cli.options[:config_file] || Gemstash::Configuration::DEFAULT_FILE
      end

      def parse_config(file)
        if file.end_with?(".erb")
          YAML.load(ERB.new(File.read(file)).result) || {}
        else
          YAML.load_file(file) || {}
        end
      end
    end
  end
end
