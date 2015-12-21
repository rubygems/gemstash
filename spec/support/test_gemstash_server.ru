require "gemstash"
use Rack::Deflater
use Gemstash::Env::RackMiddleware, $test_gemstash_server_env
use Gemstash::GemSource::RackMiddleware
run Gemstash::SinatraApp.new($test_gemstash_server_env).app
