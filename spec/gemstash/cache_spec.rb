# frozen_string_literal: true

require "spec_helper"
require "mock_redis"
require "redis"

RSpec.describe Gemstash::Cache do
  describe "authorization" do
    context "with a redis client" do
      before do
        mock_redis = MockRedis.new
        allow(Redis).to receive(:new).and_return(mock_redis)
      end

      let(:client) { Gemstash::RedisClient.new("redis://localhost:4242") }
      let(:cache) { Gemstash::Cache.new(client) }
      let(:record) { Gemstash::DB::Authorization.insert_or_update("foobarbaz", "push,fetch") }
      let(:auth) { Gemstash::Authorization.new(record) }

      it "can set and get authorization" do
        expect(cache.set_authorization("some-key", auth)).to be
        result = cache.authorization("some-key")
        expect(result.push?).to be_truthy
        expect(result.yank?).to be_falsey
        expect(result.fetch?).to be_truthy
      end
    end
  end

  describe "dependencies" do
    context "with a redis client" do
      let(:redis) { MockRedis.new }
      let(:cache) { Gemstash::Cache.new(Gemstash::RedisClient.new("redis://localhost:4242")) }
      let(:rack) { [{ :name => "rack", :number => "1.0.0", :platform => "ruby", :dependencies => [["foo", ">= 0"]] }] }

      before do
        allow(Redis).to receive(:new).and_return(redis)
      end

      def cached_dependencies(gems)
        results = {}
        cache.dependencies("upstream/https://rubygems.org", gems) {|gem, value| results[gem] = value }
        results
      end

      it "can set and get dependencies" do
        cache.set_dependency("upstream/https://rubygems.org", "rack", rack)
        expect(cached_dependencies(%w[rack missing])).to eq("rack" => rack)
      end

      it "ignores dependencies cached before they were validated" do
        redis.set("deps/v1/upstream/https://rubygems.org/rack", YAML.dump(rack))
        expect(cached_dependencies(%w[rack])).to eq({})
      end

      it "refuses to load anything but plain data" do
        redis.set("deps/v2/upstream/https://rubygems.org/rack", YAML.dump(Object.new))
        expect { cached_dependencies(%w[rack]) }.to raise_error(Psych::DisallowedClass)
      end
    end
  end
end
