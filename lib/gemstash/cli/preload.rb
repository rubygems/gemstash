require "gemstash"

module Gemstash
  class CLI
    # This implements the command line preload task to cache all the available gems:
    # $ gemstash preload
    class Preload < Gemstash::CLI::Base
      def run
        prepare
        return unless are_you_sure?
        upstream_url = @cli.options[:upstream] || gemstash_env.config[:rubygems_url]
        upstream = Gemstash::Upstream.new(upstream_url)
        http_client = Gemstash::HTTPClient.for(upstream)
        preloader = Gemstash::Preload::GemPreloader.new(upstream, http_client, @cli.options)
        preloader.preload
        @cli.say "\nDone"
      end

      def are_you_sure?
        @cli.say @cli.set_color("Preloading all the gems is an extremely heavy and long running process", :yellow)
        @cli.say @cli.set_color("You can expect that this will take around 24hs and use over 100G of disk", :yellow)
        @cli.yes? "Are you sure you want to do this?"
      end
    end
  end
end
