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
        latest = @cli.options[:latest]
        threads = @cli.options[:threads]
        http_client = HTTPClient.for(Upstream.new(@cli.options[:server_url]))
        Gemstash::Preload::GemPreloader.new(http_client, latest, threads)
      end
    end
  end
end
