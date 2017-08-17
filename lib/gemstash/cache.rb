# frozen_string_literal: true

require "lru_redux"
require "forwardable"
require "redis"

module Gemstash
  # Cache object which knows about what things are cached and what keys to use
  # for them. Under the hood is either a Memcached client via the dalli gem, or
  # an in memory client via the lru_redux gem.
  class Cache
    EXPIRY = Env.current.config[:cache_expiration]
    extend Forwardable
    def_delegators :@client, :flush

    def initialize(client)
      @client = client
    end

    def authorization(auth_key)
      @client.get("auths/#{auth_key}")
    end

    def set_authorization(auth_key, value)
      @client.set("auths/#{auth_key}", value, EXPIRY)
    end

    def invalidate_authorization(auth_key)
      @client.delete("auths/#{auth_key}")
    end

    def dependencies(scope, gems)
      key_prefix = "deps/v1/#{scope}/"
      keys = gems.map {|g| "#{key_prefix}#{g}" }

      @client.get_multi(keys) do |key, value|
        yield(key.sub(key_prefix, ""), value)
      end
    end

    def set_dependency(scope, gem, value)
      @client.set("deps/v1/#{scope}/#{gem}", value, EXPIRY)
    end

    def invalidate_gem(scope, gem)
      @client.delete("deps/v1/#{scope}/#{gem}")
      Gemstash::SpecsBuilder.invalidate_stored if scope == "private"
    end
  end

  # Wrapper around the lru_redux gem to behave like a dalli Memcached client.
  class LruReduxClient
    MAX_SIZE = Env.current.config[:cache_max_size]
    EXPIRY = Gemstash::Cache::EXPIRY
    extend Forwardable
    def_delegators :@cache, :delete
    def_delegator :@cache, :[], :get
    def_delegator :@cache, :clear, :flush

    def initialize
      @cache = LruRedux::TTL::ThreadSafeCache.new MAX_SIZE, EXPIRY
    end

    def alive!
      true
    end

    def get_multi(keys)
      keys.each do |key|
        found = true
        # Atomic fetch... don't rely on nil meaning missing
        value = @cache.fetch(key) { found = false }
        next unless found

        yield(key, value)
      end
    end

    def set(key, value, expiry)
      @cache[key] = value
    end
  end

  # Wrapper around the redis-rb gem to behave like a dalli Memcached client.
  class RedisClient
    extend Forwardable

    def_delegators :@cache, :delete
    def_delegators :@cache, :get

    def initialize(redis_servers)
      @cache = ::Redis.new(:url => redis_servers)
    end

    def alive!
      @cache.ping == "PONG"
    end

    def get_multi(keys)
      @cache.mget(*keys).each do |k, v|
        next if v.nil?
        yield(k, v)
      end
    end

    def set(key, value, expiry)
      @cache.set(key, value, :ex => expiry)
    end

    def flush
      @cache.flushdb
    end
  end
end
