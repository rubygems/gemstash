# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "fileutils"
require "rack/test"

RSpec.describe Gemstash::Web do
  include Rack::Test::Methods

  let(:http_client_builder) do
    Class.new do
      def for(server_url, timeout = 20)
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.get("/gems/rack.gem") { [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"] }
          stub.get("/gems/rack-1.0.0.gem") { [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito-1.0.0"] }
          stub.get("/gems/rack-1.1.0.gem") { [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito-1.1.0"] }
          stub.get("/quick/Marshal.4.8/rack.gemspec.rz") { [200, { "CONTENT-TYPE" => "octet/stream" }, "specatito"] }
          stub.get("/quick/Marshal.4.8/rack-1.0.0.gemspec.rz") do
            [200, { "CONTENT-TYPE" => "octet/stream" }, "specatito-1.0.0"]
          end
          stub.get("/quick/Marshal.4.8/rack-1.1.0.gemspec.rz") do
            [200, { "CONTENT-TYPE" => "octet/stream" }, "specatito-1.1.0"]
          end
        end
        client = Faraday.new {|builder| builder.adapter(:test, stubs) }
        Gemstash::HTTPClient.new(client)
      end
    end.new
  end
  let(:app) do
    Gemstash::Web.new(http_client_builder: http_client_builder,
                      gemstash_env: test_env)
  end
  let(:upstream) { "https://rubygems.org" }
  let(:gem_source) { Gemstash::GemSource::RubygemsSource }

  let(:rack_env) do
    {
      "gemstash.gem_source" => gem_source,
      "gemstash.upstream" => upstream
    }
  end

  context "when an upstream request fails" do
    let(:upstream_status) { 401 }
    let(:http_client_builder) do
      status = upstream_status
      Class.new do
        define_method(:for) do |_server_url|
          Class.new do
            define_method(:get) {|_path| raise Gemstash::WebError.new("PRIVATE-UPSTREAM-MSG", status) }
          end.new
        end
      end.new
    end

    it "returns a generic bad gateway without leaking or logging a backtrace" do
      get "/specs.4.8.gz", {}, rack_env
      expect(last_response.status).to eq(502)
      expect(JSON.parse(last_response.body)).to eq("error" => "Upstream request failed", "code" => 502)
      expect(the_log).to include("Upstream request failed (HTTP 401)")
      expect(the_log).not_to include("PRIVATE-UPSTREAM-MSG", "web.rb:")
    end

    it "does not dump the handled error through Sinatra in production" do
      allow(app.settings).to receive(:dump_errors?).and_return(true)
      get "/specs.4.8.gz", {}, rack_env
      expect(last_response.status).to eq(502)
      expect(the_log).to include("Upstream request failed (HTTP 401)")
      expect(the_log).not_to include("PRIVATE-UPSTREAM-MSG", "web.rb:")
    end

    [304, 404].each do |upstream_status|
      context "with upstream HTTP #{upstream_status}" do
        let(:upstream_status) { upstream_status }

        it "does not forward an upstream authentication or cache status" do
          get "/specs.4.8.gz", {}, rack_env
          code = upstream_status == 404 ? 404 : 502
          expect(last_response.status).to eq(code)
          expect(JSON.parse(last_response.body)).to eq("error" => "Upstream request failed", "code" => code)
          expect(last_response.body).not_to include("PRIVATE-UPSTREAM-MSG")
        end
      end
    end
  end

  let(:rack) do
    {
      :name => "rack",
      :number => "1.0.0",
      :platform => "ruby",
      :dependencies => []
    }
  end

  context "GET /" do
    let(:request) { "/" }

    it "redirects to rubygems.org" do
      get request, {}, rack_env

      expect(last_response).to redirect_to("https://rubygems.org")
      expect(last_response.headers["CACHE-CONTROL"]).to include("public")
    end

    it "does not publicly cache a redirect with client-supplied credentials" do
      get request, {}, rack_env.merge("gemstash.upstream" => "https://client:secret@rubygems.org",
                                      "HTTP_X_GEMFILE_SOURCE" => "https://client:secret@rubygems.org")

      expect(last_response.status).to eq(302)
      expect(last_response.headers["LOCATION"]).to eq("https://client:secret@rubygems.org")
      expect(last_response.headers["CACHE-CONTROL"]).to eq("no-store")
    end
  end

  context "GET /versions" do
    let(:request) { "/versions" }

    context "with https://rubygems.org upstream" do
      it "redirects to https://index.rubygems.org" do
        get request, {}, rack_env

        expect(last_response).to redirect_to("https://index.rubygems.org/versions")
      end
    end

    context "with a non https://rubygems.org upstream" do
      let(:upstream) { "https://private-gem-server.net" }

      it "redirects to the same upstream" do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([upstream])
        get request, {}, rack_env

        expect(last_response).to redirect_to("#{upstream}/versions")
      end
    end
  end

  it "does not disclose configured credentials in a redirect for a credential-free source" do
    allow(test_env.config).to receive(:[]).and_call_original
    allow(test_env.config).to receive(:[]).with(:rubygems_url).and_return("https://server:secret@private-gem-server.net")
    redirect_env = rack_env.merge("gemstash.gem_source" => Gemstash::GemSource::RedirectSource,
                                  "gemstash.upstream" => "https://private-gem-server.net")

    [redirect_env,
     rack_env.merge("gemstash.gem_source" => Gemstash::GemSource::UpstreamSource,
                    "gemstash.upstream" => "https://private-gem-server.net"),
     rack_env.merge("gemstash.upstream" => "https://private-gem-server.net")].each do |route_env|
      get "/names", {}, route_env
      expect(last_response.status).to eq(302)
      expect(last_response.headers["LOCATION"]).to eq("https://private-gem-server.net/names")
    end

    get "/names", {}, redirect_env.merge("gemstash.upstream" => "https://client:password@private-gem-server.net")
    expect(last_response.headers["LOCATION"]).to eq("https://client:password@private-gem-server.net/names")
    expect(last_response.headers["CACHE-CONTROL"]).to eq("no-store")
  end

  it "omits configured credentials on default and upstream redirect routes" do
    original_env = test_env
    config = Gemstash::Configuration.new(config: { rubygems_url: "http://server:secret@127.0.0.1:9961" })
    current_env = Gemstash::Env.new(config, db: TEST_DB)
    allow(self).to receive(:app).and_return(Gemstash::GemSource::RackMiddleware.new(Gemstash::Web.new(gemstash_env: current_env)))

    ["/names", "/upstream/http%3A%2F%2F127.0.0.1%3A9961/names"].each do |path|
      get path, {}, "REQUEST_URI" => path, "gemstash.env" => current_env
      expect(last_response.status).to eq(302)
      expect(last_response.headers["LOCATION"]).to eq("http://127.0.0.1:9961/names")
    end
  ensure
    Gemstash::Env.current = original_env if original_env
  end

  it "does not reparse a credential-bearing redirect with a UTF-8 query" do
    allow(test_env.config).to receive(:[]).and_call_original
    allow(test_env.config).to receive(:[]).with(:rubygems_url).and_return("https://server:secret@private-gem-server.net")
    get "/names", {}, rack_env.merge("gemstash.upstream" => "https://private-gem-server.net",
                                     "QUERY_STRING" => "name=café")

    expect(last_response.status).to eq(302)
    expect(last_response.headers["LOCATION"]).not_to include("server:secret")
    expect(the_log).not_to include("server:secret")
  end

  it "rejects a malformed credential-bearing client source without logging its credentials" do
    get "/gems/plain-1.0.gem", {}, rack_env.merge("gemstash.upstream" => "http://client:secret@invalid host/")
    expect(last_response.status).to eq(502)
    expect(last_response.body).not_to include("client", "secret")
    expect(the_log).not_to include("client", "secret")
  end

  it "does not log an escaped upstream route containing client credentials" do
    path = "/upstream/http%253A%252F%252Fclient%253Asecret%2540private-gem-server.net/names"
    live_app = Gemstash::GemSource::RackMiddleware.new(app)
    allow(self).to receive(:app).and_return(live_app)
    get path, {}, "REQUEST_URI" => path, "gemstash.env" => test_env

    expect(last_response.status).to eq(403)
    expect(the_log).not_to include("client%253Asecret", "client:secret")
  end

  it "does not carry client credentials onto the rubygems index hostname" do
    original_env = test_env
    config = Gemstash::Configuration.new(config: { rubygems_url: "https://rubygems.org" })
    current_env = Gemstash::Env.new(config, db: TEST_DB)
    allow(self).to receive(:app).and_return(Gemstash::Web.new(gemstash_env: current_env))
    get "/versions", {}, rack_env.merge("gemstash.upstream" => "https://client:secret@rubygems.org",
                                        "HTTP_X_GEMFILE_SOURCE" => "https://client:secret@rubygems.org",
                                        "gemstash.env" => current_env)
    expect(last_response.status).to eq(302)
    expect(last_response.headers["LOCATION"]).to eq("https://index.rubygems.org/versions")
  ensure
    Gemstash::Env.current = original_env if original_env
  end

  it "does not place upstream credentials in dependency cache keys" do
    allow(test_env.config).to receive(:[]).and_call_original
    allow(test_env.config).to receive(:[]).with(:rubygems_url).and_return("https://rubygems.org")
    response = Gemstash::Dependencies::Fetcher.private_instance_methods(false).include?(:parse_dependencies) ? "[]" : Marshal.dump([])
    allow(http_client_builder).to receive(:for).and_return(double(get: response))
    # Every cache backend (memory, memcached, redis) is written through its client's #set, so watch the keys there.
    allow(test_env.cache_client).to receive(:set).and_call_original
    get "/api/v1/dependencies.json?gems=missing", {}, rack_env.merge("gemstash.upstream" => "https://client:secret@rubygems.org")

    expect(last_response.status).to eq(200)
    expect(test_env.cache_client).to have_received(:set).at_least(:once)
    expect(test_env.cache_client).not_to have_received(:set).with(a_string_matching(/client|secret/), any_args)
  end

  context "GET /info/*" do
    let(:request) { "/info/some-gem" }

    context "with https://rubygems.org upstream" do
      it "redirects to https://index.rubygems.org" do
        get request, {}, rack_env

        expect(last_response).to redirect_to("https://index.rubygems.org/info/some-gem")
      end
    end

    context "with a non https://rubygems.org upstream" do
      let(:upstream) { "https://private-gem-server.net" }

      it "redirects to the same upstream" do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([upstream])
        get request, {}, rack_env

        expect(last_response).to redirect_to("#{upstream}/info/some-gem")
      end
    end
  end

  context "GET /api/v1/dependencies" do
    let(:request) { "/api/v1/dependencies" }

    context "there are no gems" do
      it "returns an empty string" do
        get request, {}, rack_env

        expect(last_response).to be_ok
        expect(last_response.body).to eq("")
      end
    end

    context "there are gems" do
      before do
        Gemstash::Env.current.cache.set_dependency("upstream/#{upstream}", "rack", [rack])
      end

      it "returns a marshal dump" do
        get "#{request}?gems=rack", {}, rack_env

        expect(last_response).to be_ok
        expect(Marshal.load(last_response.body)).to eq([rack])
      end
    end

    context "there are too many gems" do
      let(:gems) { Array.new(201) {|i| "gem-#{i}" }.join(",") }

      it "returns a 422" do
        get "#{request}?gems=#{gems}", {}, rack_env

        expect(last_response).not_to be_ok
        expect(last_response.body).
          to eq("Too many gems (use --full-index instead)")
      end
    end
  end

  context "GET /api/v1/dependencies.json" do
    let(:request) { "/api/v1/dependencies.json" }

    context "there are no gems" do
      it "returns an empty string" do
        get request, {}, rack_env

        expect(last_response).to be_ok
        expect(last_response.body).to eq("")
      end
    end

    context "there are gems" do
      let(:rack) do
        {
          :name => "rack",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }
      end

      before do
        Gemstash::Env.current.cache.set_dependency("upstream/#{upstream}", "rack", [rack])
      end

      it "returns a marshal dump" do
        result = [{
          "name" => "rack",
          "number" => "1.0.0",
          "platform" => "ruby",
          "dependencies" => []
        }]

        get "#{request}?gems=rack", {}, rack_env

        expect(last_response).to be_ok
        expect(JSON.parse(last_response.body)).to eq(result)
      end
    end

    context "there are too many gems" do
      let(:gems) { Array.new(201) {|i| "gem-#{i}" }.join(",") }

      it "returns a 422" do
        error = {
          "error" => "Too many gems (use --full-index instead)",
          "code" => 422
        }.to_json

        get "#{request}?gems=#{gems}", {}, rack_env

        expect(last_response).not_to be_ok
        expect(last_response.body).to eq(error)
      end
    end
  end

  context "GET /gems/:id" do
    context "from the default upstream" do
      let(:current_env) { Gemstash::Env.current }
      let(:upstream) { Gemstash::Upstream.new(current_env.config[:rubygems_url]) }
      let(:storage) { Gemstash::Storage.for("gem_cache").for(upstream.host_id) }

      it "fetches the gem file, stores, and serves it" do
        get "/gems/rack.gem", {}, rack_env
        expect(last_response.body).to eq("zapatito")
        expect(last_response.headers["CONTENT-TYPE"]).to eq("octet/stream")
        expect(storage.resource("rack").exist?(:gem)).to be_truthy
      end

      it "shares a cache across fragment variants but isolates client credentials" do
        ["https://rubygems.org#one", "https://rubygems.org#two", "https://junk1@rubygems.org#one", "https://junk1@rubygems.org#two", "https://junk2@rubygems.org"].each do |source|
          get "/gems/rack.gem", {}, rack_env.merge("gemstash.upstream" => source)
          expect(last_response.status).to eq(200)
        end
        expect(storage.resource("rack").exist?(:gem)).to be(true)
        expect(Gemstash::DB::CachedRubygem.count).to eq(3)
        expect(Gemstash::DB::Upstream.all.map(&:uri).join).not_to include("junk1", "junk2")
        expect(Pathname.new(TEST_BASE_PATH).glob("gem_cache/**/properties.yaml").map(&:read).join).not_to include("junk1", "junk2")
      end

      it "shares a cache across spellings of the host that differ only in case" do
        ["https://rubygems.org", "https://RubyGems.org", "https://client:secret@RUBYGEMS.ORG", "https://client:secret@RubyGems.org"].each do |source|
          get "/gems/rack.gem", {}, rack_env.merge("gemstash.upstream" => source)
          expect(last_response.status).to eq(200)
        end
        expect(Gemstash::DB::CachedRubygem.count).to eq(2)
        expect(Gemstash::DB::Upstream.all.map(&:host_id)).to all(start_with("rubygems.org_"))
      end

      it "reuses an existing credentialed upstream row on its next cache miss" do
        source = "https://client:secret@rubygems.org"
        cached_source = Gemstash::Upstream.new(source)
        existing = Gemstash::DB::Upstream.create(uri: source, host_id: cached_source.host_id)

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => source)

        expect(last_response.status).to eq(200)
        expect(Gemstash::DB::Upstream.count).to eq(1)
        expect(Gemstash::DB::Upstream[existing.id].uri).to eq(cached_source.cache_uri)
        expect(Gemstash::DB::CachedRubygem.first.upstream_id).to eq(existing.id)
      end

      it "serves pre-upgrade caches when the allowed entry has different trailing slash spelling" do
        [
          ["https://rubygems.org", "https://rubygems.org/"],
          ["https://rubygems.org/", "https://rubygems.org"],
          ["https://rubygems.org", "https://client:secret@rubygems.org/"]
        ].each_with_index do |(allowed, client), index|
          allow(test_env.config).to receive(:[]).and_call_original
          allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([allowed])
          source = Gemstash::Upstream.new(client)
          old = Gemstash::DB::Upstream.create(uri: client, host_id: source.host_id)
          Gemstash::Storage.for("gem_cache").for(source.host_id).resource("rack-1.0.0").save(gem: "PRE-UPGRADE-#{index}")

          get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => client, "HTTP_X_GEMFILE_SOURCE" => client)

          expect(last_response.status).to eq(200)
          expect(last_response.body).to eq("PRE-UPGRADE-#{index}")
          expect(old.reload.uri).to eq(source.cache_uri)
        end
      end

      it "serves a configured-source cache to the same resource URL without mixing credentials" do
        [
          ["https://rubygems.org/", "https://rubygems.org", "CONFIGURED-OLD-CACHE"],
          ["https://server:secret@rubygems.org/", "https://rubygems.org", "PRIVATE-OLD-CACHE"],
          ["https://rubygems.org/private//", "https://rubygems.org/private/", "zapatito-1.0.0"]
        ].each do |configured, client, expected|
          allow(test_env.config).to receive(:[]).and_call_original
          allow(test_env.config).to receive(:[]).with(:rubygems_url).and_return(configured)
          source = Gemstash::Upstream.new(configured)
          Gemstash::DB::Upstream.create(uri: configured, host_id: source.host_id)
          Gemstash::Storage.for("gem_cache").for(source.host_id).resource("rack-1.0.0").save(gem: expected == "zapatito-1.0.0" ? "WRONG-PATH-CACHE" : expected)

          get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => client, "HTTP_X_GEMFILE_SOURCE" => client)

          expect(last_response.status).to eq(200)
          expect(last_response.body).to eq(expected)
        end
      end

      it "does not read a configured-source cache under different client credentials" do
        configured = "https://rubygems.org/"
        client = "https://client:secret@rubygems.org"
        source = Gemstash::Upstream.new(configured)
        Gemstash::DB::Upstream.create(uri: configured, host_id: source.host_id)
        Gemstash::Storage.for("gem_cache").for(source.host_id).resource("rack-1.0.0").save(gem: "OTHER-CREDENTIAL-CACHE")

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => client, "HTTP_X_GEMFILE_SOURCE" => client)

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("zapatito-1.0.0")
      end

      it "finds a credentialed configured cache after an earlier credentialless match" do
        configured = "https://server:secret@rubygems.org/"
        client = "https://server:secret@rubygems.org"
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([configured])
        source = Gemstash::Upstream.new(configured)
        Gemstash::DB::Upstream.create(uri: configured, host_id: source.host_id)
        Gemstash::Storage.for("gem_cache").for(source.host_id).resource("rack-1.0.0").save(gem: "LATER-CONFIGURED-CACHE")

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => client, "HTTP_X_GEMFILE_SOURCE" => client)

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("LATER-CONFIGURED-CACHE")
      end

      it "uses the exact client's cache when the database returns a differently cased host id" do
        source = "https://rubygems.org/"
        alternate = "https://RUBYGEMS.ORG/"
        allow(test_env.config).to receive(:[]).and_call_original
        record = Gemstash::DB::Upstream.create(uri: alternate, host_id: Gemstash::Upstream.new(alternate).host_id)
        Gemstash::Storage.for("gem_cache").for(record.host_id).resource("rack-1.0.0").save(gem: "OTHER-SOURCE-CACHE")
        allow(Gemstash::DB::Upstream).to receive(:find_existing).and_return(record)

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => source, "HTTP_X_GEMFILE_SOURCE" => source)

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("zapatito-1.0.0")
      end

      it "scrubs a legacy encoded credential and path row while keeping its cached gem references" do
        source = "https://client:p%61ssword@rubygems.org/private%2Fteam"
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["https://rubygems.org/private%2Fteam", "https://rubygems.org/private/team"])
        cached_source = Gemstash::Upstream.new(source)
        legacy_uri = CGI.unescape(source)
        legacy_id = "rubygems.org_#{Digest::MD5.hexdigest(legacy_uri)}"
        existing = Gemstash::DB::Upstream.create(uri: legacy_uri, host_id: legacy_id)
        Gemstash::DB::CachedRubygem.create(upstream_id: existing.id, name: "rack-1.0.0", resource_type: "gem")
        Gemstash::Storage.for("gem_cache").for(legacy_id).resource("rack-1.0.0").save(gem: "LEGACY-CACHED-GEM")

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => source)

        expect(last_response.status).to eq(200)
        expect(last_response.body).to eq("zapatito-1.0.0")
        expect(Gemstash::DB::Upstream.count).to eq(2)
        expect(existing.reload.uri).to eq(Gemstash::Upstream.new(URI(legacy_uri)).cache_uri)
        expect(existing.host_id).to eq(legacy_id)
        expect(Gemstash::DB::Upstream[uri: cached_source.cache_uri].host_id).to eq(cached_source.host_id)
        expect(Gemstash::DB::CachedRubygem.where(upstream_id: existing.id).count).to eq(1)

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => legacy_uri)
        expect(last_response.body).to eq("LEGACY-CACHED-GEM")
        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => source)
        expect(last_response.body).to eq("zapatito-1.0.0")
      end

      it "keeps an uncredentialed legacy path cache separate from its encoded source" do
        source = "https://rubygems.org/private%2Fteam"
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([source, "https://rubygems.org/private/team"])
        legacy_uri = CGI.unescape(source)
        legacy_id = "rubygems.org_#{Digest::MD5.hexdigest(legacy_uri)}"
        existing = Gemstash::DB::Upstream.create(uri: legacy_uri, host_id: legacy_id)
        Gemstash::Storage.for("gem_cache").for(legacy_id).resource("rack-1.0.0").save(gem: "PLAIN-LEGACY-CACHE")

        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => source)
        expect(last_response.body).to eq("zapatito-1.0.0")
        get "/gems/rack-1.0.0.gem", {}, rack_env.merge("gemstash.upstream" => legacy_uri)
        expect(last_response.body).to eq("PLAIN-LEGACY-CACHE")
        expect(Gemstash::DB::Upstream.count).to eq(2)
        expect(existing.reload.uri).to eq(legacy_uri)
      end

      it "forwards client Basic credentials on header and upstream routes over a real socket" do
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        received = []
        server_thread = Thread.new do
          14.times do
            socket = server.accept
            headers = []
            while (line = socket.gets) && line != "\r\n"
              headers << line
            end
            received << headers.grep(/\AAuthorization:/i).first.to_s.strip
            socket.write("HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nAUTHORIZED")
            socket.close
          end
        end
        original_env = test_env

        [{ rubygems_url: "http://127.0.0.1:#{port}" },
         { allowed_upstreams: ["*"] }].each_with_index do |settings, config_index|
          config = Gemstash::Configuration.new(config: settings.merge(allowed_upstreams: settings.fetch(:allowed_upstreams, ["http://127.0.0.1:#{port}"])))
          current_env = Gemstash::Env.new(config, db: TEST_DB)
          live_app = Gemstash::GemSource::RackMiddleware.new(Gemstash::Web.new(gemstash_env: current_env))
          allow(self).to receive(:app).and_return(live_app)
          ["user:password", "TOKEN"].each_with_index do |credential, index|
            source = "http://#{credential}@127.0.0.1:#{port}/"
            path = "/gems/header-#{config_index}-#{index}.gem"
            get path, {}, "REQUEST_URI" => path, "HTTP_X_GEMFILE_SOURCE" => source, "gemstash.env" => current_env
            expect(last_response.status).to eq(200)
            path = "/upstream/#{CGI.escape(source)}/gems/route-#{config_index}-#{index}.gem"
            get path, {}, "REQUEST_URI" => path, "gemstash.env" => current_env
            expect(last_response.status).to eq(200)
          end
        end
        encoded_source = "http://user:p%40ss@127.0.0.1:#{port}/"
        path = "/gems/encoded-header-1.0.gem"
        get path, {}, "REQUEST_URI" => path, "HTTP_X_GEMFILE_SOURCE" => encoded_source, "gemstash.env" => current_env
        expect(last_response.status).to eq(200)
        path = "/upstream/#{CGI.escape(encoded_source)}/gems/encoded-route-1.0.gem"
        get path, {}, "REQUEST_URI" => path, "gemstash.env" => current_env
        expect(last_response.status).to eq(200)

        plus_source = "http://user:p+ss@127.0.0.1:#{port}/"
        path = "/gems/plus-header-1.0.gem"
        get path, {}, "REQUEST_URI" => path, "HTTP_X_GEMFILE_SOURCE" => plus_source, "gemstash.env" => current_env
        expect(last_response.status).to eq(200)
        path = "/upstream/#{CGI.escape(plus_source)}/gems/plus-route-1.0.gem"
        get path, {}, "REQUEST_URI" => path, "gemstash.env" => current_env
        expect(last_response.status).to eq(200)

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMSTASH_127__0__0__1").and_return("server:secret")
        ["user:password", "TOKEN"].each_with_index do |credential, index|
          path = "/gems/override-#{index}.gem"
          get path, {}, "REQUEST_URI" => path,
                        "HTTP_X_GEMFILE_SOURCE" => "http://#{credential}@127.0.0.1:#{port}/", "gemstash.env" => current_env
          expect(last_response.status).to eq(200)
        end

        expect(received).to eq((["Authorization: Basic dXNlcjpwYXNzd29yZA=="] * 2 + ["Authorization: Basic VE9LRU46"] * 2) * 2 +
          ["Authorization: Basic dXNlcjpwQHNz"] * 2 + ["Authorization: Basic dXNlcjpwK3Nz"] * 2 +
          ["Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Basic VE9LRU46"])
        expect(the_log).not_to include("password", "TOKEN", "dXNlcjpwYXNzd29yZA==", "VE9LRU46")
      ensure
        Gemstash::Env.current = original_env if original_env
        server_thread&.kill
        server_thread&.join
        server&.close
      end

      it "keeps the upstream and full gem name in the properties" do
        get "/gems/rack-1.0.0.gem", {}, rack_env
        properties = storage.resource("rack-1.0.0").properties
        expect(properties[:upstream]).to eq(upstream.to_s)
        expect(properties[:gem_name]).to eq("rack-1.0.0")
      end

      it "keeps headers for specs that have been previously fetched" do
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        get "/gems/rack.gem", {}, rack_env
        expect(storage.resource("rack").properties[:headers][:spec]).to eq("content-type" => "octet/stream")
        expect(storage.resource("rack").properties[:headers][:gem]).to eq("content-type" => "octet/stream")
      end

      it "indexes the cached gem" do
        get "/gems/rack.gem", {}, rack_env
        db_upstream = Gemstash::DB::Upstream[uri: upstream.to_s]
        expect(db_upstream).to be_an_instance_of(Gemstash::DB::Upstream)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack", resource_type: "gem"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
      end

      it "indexes specs of different versions separately" do
        get "/gems/rack-1.0.0.gem", {}, rack_env
        get "/gems/rack-1.1.0.gem", {}, rack_env
        db_upstream = Gemstash::DB::Upstream[uri: upstream.to_s]
        expect(db_upstream).to be_an_instance_of(Gemstash::DB::Upstream)
        expect(Gemstash::DB::CachedRubygem.count).to eq(2)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack-1.0.0", resource_type: "gem"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack-1.1.0", resource_type: "gem"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
      end

      it "can be called multiple times without error" do
        get "/gems/rack.gem", {}, rack_env
        get "/gems/rack.gem", {}, rack_env
      end

      it "can be called after the gem has been deleted" do
        get "/gems/rack.gem", {}, rack_env
        storage.resource("rack").delete(:gem)
        expect(storage.resource("rack").exist?(:gem)).to be_falsey
        get "/gems/rack.gem", {}, rack_env
        expect(last_response.body).to eq("zapatito")
        expect(last_response.headers["CONTENT-TYPE"]).to eq("octet/stream")
        expect(storage.resource("rack").exist?(:gem)).to be_truthy
      end

      it "does not ask the upstream for an id that cannot be the file name of a gem" do
        expect(http_client_builder).to_not receive(:for)

        %w[..%252F..%252Fsecret .%252E rack%3Fa=b rack%23a rack%20 rack%0A %25 rack rack.GEM rack.gemspec.rz].each do |id|
          get "/gems/#{id}", {}, rack_env
          expect(last_response.status).to eq(404), "expected #{id} to not be found"
        end
      end

      it "does not poison a gem cache entry with a suffixless id" do
        get "/gems/rack", {}, rack_env
        expect(last_response.status).to eq(404)
        expect(storage.resource("rack").exist?(:gem)).to be_falsey
        get "/gems/rack.gem", {}, rack_env
        expect(last_response.body).to eq("zapatito")
      end

      it "only accepts an id made of the characters of a gem file name" do
        valid_id = Gemstash::GemSource::UpstreamSource::VALID_ID

        %w[rack rack-1.0.0.gem nokogiri-1.16.0-x86_64-linux.gem a_b-1.0.0.pre.1-java.gemspec.rz].each do |id|
          expect(id).to match(valid_id)
        end

        ["", ".", "..", "a/b", "a\\b", "a b", "a%2Fb", "a?b", "a#b", "a\nb", "rack\n"].each do |id|
          expect(id).to_not match(valid_id)
        end
      end
    end

    context "from private gems" do
      let(:gem_source) { Gemstash::GemSource::PrivateSource }
      let(:storage) { Gemstash::Storage.for("private").for("gems") }

      context "with a missing gem" do
        it "halts with 404" do
          get "/gems/unknown-0.1.0.gem", {}, rack_env
          expect(last_response).to_not be_ok
          expect(last_response.status).to eq(404)
          expect(last_response.body).to match(/not found/i)
        end
      end

      context "with a regular gem" do
        before do
          gem_id = insert_rubygem "example"
          insert_version gem_id, "0.1.0"
          storage.resource("example-0.1.0").save({ gem: "Example gem content" }, indexed: true)
        end

        it "fetches the gem contents" do
          get "/gems/example-0.1.0.gem", {}, rack_env
          expect(last_response).to be_ok
          expect(last_response.body).to eq("Example gem content")
        end
      end

      context "with a yanked gem" do
        before do
          gem_id = insert_rubygem "yanked"
          insert_version gem_id, "0.1.0", indexed: false
          storage.resource("yanked-0.1.0").save({ gem: "Example yanked gem content" }, indexed: false)
        end

        it "halts with 403" do
          get "/gems/yanked-0.1.0.gem", {}, rack_env
          expect(last_response).to_not be_ok
          expect(last_response.status).to eq(403)
          expect(last_response.body).to_not eq("Example yanked gem content")
        end
      end
    end
  end

  context "GET /quick/Marshal.4.8/:id" do
    context "from the default upstream" do
      let(:current_env) { Gemstash::Env.current }
      let(:upstream) { Gemstash::Upstream.new(current_env.config[:rubygems_url]) }
      let(:storage) { Gemstash::Storage.for("gem_cache").for(upstream.host_id) }

      it "fetches the marshalled gemspec, stores, and serves it" do
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        expect(last_response.body).to eq("specatito")
        expect(last_response.headers["CONTENT-TYPE"]).to eq("octet/stream")
        expect(storage.resource("rack").exist?(:spec)).to be_truthy
      end

      it "keeps the upstream and full gem name in the properties" do
        get "/quick/Marshal.4.8/rack-1.0.0.gemspec.rz", {}, rack_env
        properties = storage.resource("rack-1.0.0").properties
        expect(properties[:upstream]).to eq(upstream.to_s)
        expect(properties[:gem_name]).to eq("rack-1.0.0")
      end

      it "keeps headers for gems that have been previously fetched" do
        get "/gems/rack.gem", {}, rack_env
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        expect(storage.resource("rack").properties[:headers][:gem]).to eq("content-type" => "octet/stream")
        expect(storage.resource("rack").properties[:headers][:spec]).to eq("content-type" => "octet/stream")
      end

      it "indexes the cached spec" do
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        db_upstream = Gemstash::DB::Upstream[uri: upstream.to_s]
        expect(db_upstream).to be_an_instance_of(Gemstash::DB::Upstream)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack", resource_type: "spec"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
      end

      it "indexes specs of different versions separately" do
        get "/quick/Marshal.4.8/rack-1.0.0.gemspec.rz", {}, rack_env
        get "/quick/Marshal.4.8/rack-1.1.0.gemspec.rz", {}, rack_env
        db_upstream = Gemstash::DB::Upstream[uri: upstream.to_s]
        expect(db_upstream).to be_an_instance_of(Gemstash::DB::Upstream)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack-1.0.0", resource_type: "spec"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
        expect(Gemstash::DB::CachedRubygem[upstream_id: db_upstream.id, name: "rack-1.1.0", resource_type: "spec"]).to be_an_instance_of(Gemstash::DB::CachedRubygem)
      end

      it "can be called multiple times without error" do
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        expect { get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env }.not_to raise_error
      end

      it "can be called after the spec has been deleted" do
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        storage.resource("rack").delete(:spec)
        expect(storage.resource("rack").exist?(:spec)).to eq(false)
        get "/quick/Marshal.4.8/rack.gemspec.rz", {}, rack_env
        expect(last_response.body).to eq("specatito")
        expect(last_response.headers["CONTENT-TYPE"]).to eq("octet/stream")
        expect(storage.resource("rack").exist?(:spec)).to eq(true)
      end

      it "does not ask the upstream for an id that cannot be the file name of a gemspec" do
        expect(http_client_builder).to_not receive(:for)

        %w[..%252F..%252Fsecret.gemspec.rz rack.gemspec.rz%3Fa=b].each do |id|
          get "/quick/Marshal.4.8/#{id}", {}, rack_env
          expect(last_response.status).to eq(404), "expected #{id} to not be found"
        end
      end
    end

    context "from private gems" do
      let(:gem_source) { Gemstash::GemSource::PrivateSource }
      let(:storage) { Gemstash::Storage.for("private").for("gems") }

      context "with a missing gem" do
        it "halts with 404" do
          get "/quick/Marshal.4.8/unknown-0.1.0.gemspec.rz", {}, rack_env
          expect(last_response).to_not be_ok
          expect(last_response.status).to eq(404)
          expect(last_response.body).to match(/not found/i)
        end
      end

      context "with a regular gem" do
        before do
          gem_id = insert_rubygem "example"
          insert_version gem_id, "0.1.0"
          storage.resource("example-0.1.0").save({ gem: "Example gem content",
                                                   spec: "Example gemspec content" }, indexed: true)
        end

        it "fetches the spec contents" do
          get "/quick/Marshal.4.8/example-0.1.0.gemspec.rz", {}, rack_env
          expect(last_response).to be_ok
          expect(last_response.body).to eq("Example gemspec content")
        end
      end

      context "with a yanked gem" do
        before do
          gem_id = insert_rubygem "yanked"
          insert_version gem_id, "0.1.0", indexed: false
          storage.resource("yanked-0.1.0").save({ gem: "Example yanked gem content",
                                                  spec: "Example yanked gemspec content" }, indexed: false)
        end

        it "halts with 403" do
          get "/quick/Marshal.4.8/yanked-0.1.0.gemspec.rz", {}, rack_env
          expect(last_response).to_not be_ok
          expect(last_response.status).to eq(403)
          expect(last_response.body).to_not match(/Example yanked gem(spec)? content/)
        end
      end
    end
  end

  context "with :allowed_upstreams" do
    let(:allowed_upstreams) { ["https://private-gem-server.net/"] }

    let(:upstream_routes) do
      %w[
        /
        /names
        /versions
        /info/rack
        /api/v1/dependencies?gems=rack
        /api/v1/dependencies.json?gems=rack
        /gems/rack
        /quick/Marshal.4.8/rack.gemspec.rz
        /fetch/actual/gem/rack.gem
        /specs.4.8.gz
        /latest_specs.4.8.gz
        /prerelease_specs.4.8.gz
      ]
    end

    before do
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(allowed_upstreams)
    end

    shared_examples "a refused upstream" do
      it "forbids every route without asking the upstream" do
        expect(http_client_builder).to_not receive(:for)

        upstream_routes.each do |route|
          get route, {}, rack_env
          expect(last_response.status).to eq(403), "expected #{route} to be forbidden"
          expect(last_response.body).to eq("This upstream is not allowed by the Gemstash server")
          expect(last_response.headers["CONTENT-TYPE"]).to eq("text/plain")
          expect(last_response.headers["CACHE-CONTROL"]).to eq("no-store")
          expect(last_response.headers["LOCATION"]).to be_nil
        end
      end
    end

    [
      Gemstash::GemSource::RubygemsSource,
      Gemstash::GemSource::UpstreamSource,
      Gemstash::GemSource::RedirectSource
    ].each do |source|
      context "using #{source.name.split("::").last}" do
        let(:gem_source) { source }

        context "with the default upstream" do
          it "serves the request" do
            get "/versions", {}, rack_env
            expect(last_response).to redirect_to("https://index.rubygems.org/versions")
          end
        end

        context "with an upstream that is listed" do
          let(:upstream) { "https://private-gem-server.net" }

          it "serves the request" do
            get "/versions", {}, rack_env
            expect(last_response).to redirect_to("https://private-gem-server.net/versions")
          end
        end

        context "with an upstream that is not listed" do
          let(:upstream) { "https://user:secret@other-gem-server.net/gems" }
          it_behaves_like "a refused upstream"

          it "logs the refusal without the credentials" do
            get "/versions", {}, rack_env
            expect(the_log).to include('Refusing upstream "https://other-gem-server.net:443/gems", it is not in :allowed_upstreams')
            expect(the_log).to_not include("secret")
          end
        end

        context "with a listed upstream that is requested over another scheme" do
          let(:upstream) { "http://private-gem-server.net" }
          it_behaves_like "a refused upstream"
        end

        context "with a listed upstream that is requested with another path" do
          let(:upstream) { "https://private-gem-server.net/other" }
          it_behaves_like "a refused upstream"
        end
      end
    end

    context "with an empty list" do
      let(:allowed_upstreams) { [] }

      context "with the default upstream" do
        it "serves the request" do
          get "/versions", {}, rack_env
          expect(last_response).to redirect_to("https://index.rubygems.org/versions")
        end
      end

      context "with another upstream" do
        let(:upstream) { "https://private-gem-server.net" }
        it_behaves_like "a refused upstream"
      end
    end

    context "with any upstream allowed" do
      let(:allowed_upstreams) { "*" }
      let(:upstream) { "https://other-gem-server.net" }

      it "serves the request" do
        get "/versions", {}, rack_env
        expect(last_response).to redirect_to("https://other-gem-server.net/versions")
      end
    end
  end

  context "with redirect-only routes" do
    let(:gem_source) { Gemstash::GemSource::RedirectSource }

    it "rejects ids that would change the redirected resource" do
      %w[/info/rack%3Fa=b /gems/rack /gems/rack.GEM /gems/rack.gemspec.rz /fetch/actual/gem/rack /quick/Marshal.4.8/rack.gem].each do |path|
        get path, {}, rack_env
        expect(last_response.status).to eq(404), "expected #{path} to be rejected"
        expect(last_response.headers["LOCATION"]).to be_nil
      end
    end
  end

  context "POST /api/v1/gems" do
    let(:gem_source) { Gemstash::GemSource::PrivateSource }
    let(:auth_key) { "auth-key" }
    let(:env) { rack_env.merge("CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => auth_key) }

    before do
      Gemstash::Authorization.authorize(auth_key, "all")
    end

    it "returns 200 on a successful push" do
      post "/api/v1/gems", read_gem("example", "0.1.0"), env
      expect(last_response).to be_ok
      expect(last_response.status).to eq(200)
    end

    it "returns a 422 when gem already exists" do
      post "/api/v1/gems", read_gem("example", "0.1.0"), env
      expect(last_response).to be_ok

      post "/api/v1/gems", read_gem("example", "0.1.0"), env
      expect(last_response).to_not be_ok
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)).to eq("error" => "Version already exists", "code" => 422)
    end
  end
end
