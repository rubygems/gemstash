# frozen_string_literal: true

require "gemstash"
require "puma/control_cli"

module Gemstash
  class CLI
    # This implements the command line info task:
    #  $ gemstash info
    class Info < Gemstash::CLI::Base
      include Gemstash::Env::Helper
      def run
        prepare
        list_config

        # Gemstash::DB
        # Gemstash::Env.current.db.dump_schema_migration(same_db: true)
      end

    private

      def list_config
        config = gemstash_env.config
        config_str = +""
        config.keys.map do |key|
          config_str << "#{key}: #{config[key]}\n"
        end
        config_str
      end
    end
  end
end
