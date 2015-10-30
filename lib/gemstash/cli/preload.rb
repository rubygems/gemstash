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
        return unless are_you_sure?
        http_client = HTTPClient.for(Upstream.new(@cli.options[:server_url]))
        preloader = Gemstash::Preload::GemPreloader.new(http_client, latest: @cli.options[:latest]).
          limit(@cli.options[:limit]).skip(@cli.options[:skip]).threads(@cli.options[:threads])
        preloader.preload
      end

      def are_you_sure?
        @cli.say @cli.set_color("Preloading all the gems is an extremely heavy and long running process", :yellow)
        @cli.say @cli.set_color("You can expect that this will take around 24hs and use over 100G of disk", :yellow)
        @cli.yes? "Are you sure you want to do this?"
      end
    end
  end
end
