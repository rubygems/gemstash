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

      let(:client) { Gemstash::RedisClient.new('redis://localhost:4242') }
      let(:cache) { Gemstash::Cache.new(client) }
      let(:record) { Gemstash::DB::Authorization.insert_or_update('foobarbaz', 'push,fetch') }
      let(:auth) { Gemstash::Authorization.new(record) }

      it "can set and get authorization" do
         expect(cache.set_authorization('some-key', auth)).to be
         result = cache.authorization('some-key')
         expect(result.push?).to be_truthy
         expect(result.yank?).to be_falsey
         expect(result.fetch?).to be_truthy
      end
    end
  end
end
