# frozen_string_literal: true

require "gemstash"
use Rack::Deflater
use Gemstash::Env::RackMiddleware, $test_gemstash_server_env
use Gemstash::GemSource::RackMiddleware
use Gemstash::Health::RackMiddleware
map "/set_time" do
  run lambda {|env|
        now = Time.iso8601(Rack::Request.new(env).body.read)
        $test_gemstash_server_current_test.allow(Time).
          to $test_gemstash_server_current_test.receive(:now).and_return(now)
        [200, {}, ["OK"]]
      }
end
map "/rebuild_versions_list" do
  run lambda {|_env|
    Gemstash::CompactIndexBuilder::Versions.new(nil).build_result(force_rebuild: true)
    [200, {}, ["OK"]]
  }
end
run Gemstash::Web.new(gemstash_env: $test_gemstash_server_env)
