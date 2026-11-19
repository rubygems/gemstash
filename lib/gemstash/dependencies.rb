# frozen_string_literal: true

require "json"
require "cgi"

module Gemstash
  # :nodoc:
  class Dependencies
    def self.for_private
      new(scope: "private", db_model: Gemstash::DB::Dependency)
    end

    def self.for_upstream(upstream, http_client)
      new(scope: "upstream/#{upstream.is_a?(Gemstash::Upstream) ? upstream.cache_uri : upstream}", http_client: http_client)
    end

    def initialize(scope: nil, http_client: nil, db_model: nil)
      @scope = scope
      @http_client = http_client
      @db_model = db_model
    end

    def fetch(gems)
      Fetcher.new(gems, @scope, @http_client, @db_model).fetch
    end

    # :nodoc:
    class Fetcher
      include Gemstash::Env::Helper
      include Gemstash::Logging

      FIELDS = %i[name number platform dependencies].freeze

      def initialize(gems, scope, http_client, db_model)
        @gems = Set.new(gems)
        @scope = scope
        @http_client = http_client
        @db_model = db_model
        @dependencies = []
      end

      def fetch
        fetch_from_cache
        fetch_from_database
        fetch_from_web
        cache_missing
        @dependencies
      end

    private

      def done?
        @gems.empty?
      end

      def fetch_from_cache
        gemstash_env.cache.dependencies(@scope, @gems) do |gem, value|
          @gems.delete(gem)
          @dependencies += value
        end
      end

      def fetch_from_database
        return if done?
        return unless @db_model

        log.info "Querying dependencies: #{@gems.to_a.join(", ")}"

        @db_model.fetch(@gems) do |gem, value|
          @gems.delete(gem)
          gemstash_env.cache.set_dependency(@scope, gem, value)
          @dependencies += value
        end
      end

      def fetch_from_web
        return if done?
        return unless @http_client

        log.info "Fetching dependencies: #{@gems.to_a.join(", ")}"
        gems_param = @gems.map {|gem| CGI.escape(gem) }.join(",")
        fetched = @http_client.get("api/v1/dependencies.json?gems=#{gems_param}")
        fetched = parse_dependencies(fetched).group_by {|r| r[:name] }

        fetched.each do |gem, result|
          # Only keep what was asked for
          next unless @gems.delete?(gem)

          gemstash_env.cache.set_dependency(@scope, gem, result)
          @dependencies += result
        end
      end

      # The result is cached and handed to clients, so only the fields of the
      # dependency API are taken from what the upstream sent.
      def parse_dependencies(body)
        entries = JSON.parse(body, symbolize_names: true)
        valid = entries.is_a?(Array) && entries.all? {|entry| valid_entry?(entry) }
        raise Gemstash::WebError.new("Unexpected dependency data from the upstream", 502) unless valid

        entries.map {|entry| entry.slice(*FIELDS) }
      rescue JSON::ParserError
        raise Gemstash::WebError.new("Dependency data from the upstream is not valid JSON", 502)
      end

      def valid_entry?(entry)
        entry.is_a?(Hash) &&
          entry.values_at(:name, :number, :platform).all?(String) &&
          entry[:dependencies].is_a?(Array) &&
          entry[:dependencies].all? {|dependency| dependency.is_a?(Array) && dependency.size == 2 && dependency.all?(String) }
      end

      def cache_missing
        @gems.each do |gem|
          gemstash_env.cache.set_dependency(@scope, gem, [])
        end
      end
    end
  end
end
