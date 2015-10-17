require "gemstash"

module Gemstash
  class CLI
    # This implements the command line preload task to cache all the available gems:
    # $ gemstash preload
    class Preload
      include Gemstash::Env::Helper

      def initialize(cli)
        Gemstash::Env.current = Gemstash::Env.new
        @cli = cli
      end

      def run
      end
    end
  end
end
