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
      end

    private

      def list_config
        @config = gemstash_env.config
        @config.keys.map do |key|
          @cli.say "#{key}: #{@config[key]}"
        end
      end
    end
  end
end
