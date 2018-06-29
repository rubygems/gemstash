module Gemstash
  class Versions
    def self.for_upstream(upstream, http_client)
      new(scope: "upstream/#{upstream}", http_client: http_client)
    end

    def initialize(scope: nil, http_client: nil)
      @scope = scope
      @http_client = http_client
    end

    def fetch
      Fetcher.new(@scope, @http_client).fetch
    end

    class Fetcher
      include Gemstash::Env::Helper
      include Gemstash::Logging

      def initialize(scope, http_client)
        @scope = scope
        @http_client = http_client
        @versions = ""
      end

      def fetch
        fetch_from_cache
        @versions
      end

      private

      def fetch_from_cache
        @versions = gemstash_env.cache.versions(@scope)
      end
    end
  end
end
