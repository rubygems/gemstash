# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::HTTPClient do
  before(:all) do
    @server = SimpleServer.new("localhost")
    @other_server = SimpleServer.new("127.0.0.1")
    @server.mount_message("/simple_fetch", "Simple fetch results")
    @server.mount_message("/nested/fetch", "Nested fetch results")
    @server.mount_message("/error", "Error result", 500)
    @server.mount_message("/missing", "Missing value", 404)
    @server.mount_redirect("/redirect", "/simple_fetch")
    @server.mount_redirect("/other_redirect", "#{@other_server.url}/redirect")
    @server.mount_redirect("/upgrade", "https://localhost:#{URI(@server.url).port}/safe")
    @server.mount_redirect("/userinfo_redirect", "http://localhost:#{URI(@server.url).port}%2F@127.0.0.1:#{URI(@other_server.url).port}/secret")
    @other_server.mount_message("/secret", "UNLISTED-LOOPBACK-MARKER")
    @other_server.mount_redirect("/redirect", "#{@server.url}/simple_fetch")
    @server.start
    @other_server.start
  end

  after(:all) do
    @server.stop
    @other_server.stop
  end

  describe "#for" do
    context "when user:pass auth is in the upstream url" do
      let(:upstream) { Gemstash::Upstream.new("https://username:password@localhost/") }
      subject { Gemstash::HTTPClient.for(upstream).client.headers }
      it { is_expected.to include("Authorization" => "Basic dXNlcm5hbWU6cGFzc3dvcmQ=") }
    end

    context "when user:pass auth is set by ENV variable" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMSTASH_LOCALHOST").and_return("username:password")
      end

      let(:upstream) { Gemstash::Upstream.new("https://localhost/") }
      subject { Gemstash::HTTPClient.for(upstream).client.headers }
      it { is_expected.to include("Authorization" => "Basic dXNlcm5hbWU6cGFzc3dvcmQ=") }
    end

    context "when api_key auth is in the upstream url" do
      let(:upstream) { Gemstash::Upstream.new("https://api_key@localhost/") }
      subject { Gemstash::HTTPClient.for(upstream).client.headers }
      it { is_expected.to include("Authorization" => "Basic YXBpX2tleTo=") }
    end

    context "when api_key auth is set by ENV variable" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMSTASH_LOCALHOST").and_return("api_key")
      end

      let(:upstream) { Gemstash::Upstream.new("https://localhost/") }
      subject { Gemstash::HTTPClient.for(upstream).client.headers }
      it { is_expected.to include("Authorization" => "Basic YXBpX2tleTo=") }
    end

    context "when no auth is included in the upstream url" do
      let(:upstream) { Gemstash::Upstream.new("https://localhost/") }
      subject { Gemstash::HTTPClient.for(upstream).client.headers }
      it { is_expected.to_not include("Authorization") }
    end
  end

  describe ".get" do
    let(:http_client) do
      Gemstash::HTTPClient.for(Gemstash::Upstream.new(@server.url))
    end

    context "with a valid url" do
      it "returns the body of the result" do
        expect(http_client.get("simple_fetch")).to eq("Simple fetch results")
      end
    end

    context "with an upstream that includes a path" do
      let(:http_client) do
        Gemstash::HTTPClient.for(Gemstash::Upstream.new("#{@server.url}/nested"))
      end

      it "returns the body of the result" do
        expect(http_client.get("fetch")).to eq("Nested fetch results")
      end
    end

    context "with a valid redirect" do
      before do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([@server.url])
      end

      it "returns the body of the result after the redirect" do
        expect(http_client.get("redirect")).to eq("Simple fetch results")
      end
    end

    context "with a redirect to a different server" do
      before do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([@server.url, @other_server.url])
      end

      it "returns the body of the result after the redirects" do
        expect(http_client.get("other_redirect")).to eq("Simple fetch results")
      end
    end

    it "refuses a raw Location with encoded userinfo rather than fetching its socket target" do
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([@server.url])
      expect { http_client.get("userinfo_redirect") }.to raise_error(Gemstash::WebError) {|error| expect(error.code).to eq(502) }
    end

    it "maps a redirect loop to a gateway error without disclosing its Location" do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Gemstash::HTTPClient.for(Gemstash::Upstream.new(@server.url))
      client.client.builder.adapter(:test, stubs)
      4.times { stubs.get("#{@server.url}/loop") { [302, { "Location" => "/loop" }, ""] } }
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([@server.url])
      expect { client.get("loop") }.to raise_error(Gemstash::WebError) do |error|
        expect(error.code).to eq(502)
        expect(error.message).not_to include("loop", "http")
      end
    end

    it "maps TLS failures to a gateway error without disclosing the upstream URL" do
      stubs = Faraday::Adapter::Test::Stubs.new
      client = Gemstash::HTTPClient.for(Gemstash::Upstream.new(@server.url))
      client.client.builder.adapter(:test, stubs)
      stubs.get("#{@server.url}/tls") { raise Faraday::SSLError, "https://user:secret@localhost/private?token=secret" }
      expect { client.get("tls") }.to raise_error(Gemstash::WebError) do |error|
        expect(error.code).to eq(502)
        expect(error.message).not_to include("secret", "localhost")
      end
    end

    it "follows a relative redirect with token-only basic auth, without forwarding credentials to another host" do
      server = TCPServer.new("127.0.0.1", 0)
      other_server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      other_port = other_server.addr[1]
      headers = []
      socket_thread = Thread.new do
        2.times do |hop|
          socket = server.accept
          while (line = socket.gets) && line != "\r\n"
            headers << line if line.start_with?("Authorization:")
          end
          if hop.zero?
            socket.write("HTTP/1.1 302 Found\r\nLocation: /plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          else
            socket.write("HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nAUTHORIZED")
          end
          socket.close
        end
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"; end
        socket.write("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:#{other_port}/plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close
      end
      other_thread = Thread.new do
        socket = other_server.accept
        while (line = socket.gets) && line != "\r\n"
          headers << "LEAKED" if line.start_with?("Authorization:")
        end
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nNO-AUTH")
        socket.close
      end
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["http://127.0.0.1:#{port}", "http://127.0.0.1:#{other_port}"])
      client = Gemstash::HTTPClient.for(Gemstash::Upstream.new("http://TOKEN@127.0.0.1:#{port}"))

      expect(client.get("redirect")).to eq("AUTHORIZED")
      expect(client.get("cross_redirect")).to eq("NO-AUTH")
      expect(headers).to eq(["Authorization: Basic #{["TOKEN:"].pack("m0")}\r\n"] * 2)
    ensure
      socket_thread&.kill
      other_thread&.kill
      socket_thread&.join
      other_thread&.join
      server&.close
      other_server&.close
    end

    it "does not forward upstream credentials across a scheme-relative redirect" do
      source = TCPServer.new("127.0.0.1", 0)
      destination = TCPServer.new("127.0.0.1", 0)
      source_port = source.addr[1]
      destination_port = destination.addr[1]
      received = []
      source_thread = Thread.new do
        socket = source.accept
        while (line = socket.gets) && line != "\r\n"
          received << line if line.start_with?("Authorization:")
        end
        socket.write("HTTP/1.1 302 Found\r\nLocation: //127.0.0.1:#{destination_port}/plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close
      end
      destination_thread = Thread.new do
        socket = destination.accept
        while (line = socket.gets) && line != "\r\n"
          received << "LEAKED" if line.start_with?("Authorization:")
        end
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nSAFE")
        socket.close
      end
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["http://127.0.0.1:#{source_port}", "http://127.0.0.1:#{destination_port}"])
      client = Gemstash::HTTPClient.for(Gemstash::Upstream.new("http://user:s3cret@127.0.0.1:#{source_port}"))

      expect(client.get("redirect")).to eq("SAFE")
      expect(received).to eq(["Authorization: Basic #{["user:s3cret"].pack("m0")}\r\n"])
    ensure
      source_thread&.kill
      destination_thread&.kill
      source_thread&.join
      destination_thread&.join
      source&.close
      destination&.close
    end

    it "follows a redirect from an allowed IPv6 loopback upstream" do
      server = TCPServer.new("::1", 0)
      socket_thread = Thread.new do
        2.times do |hop|
          socket = server.accept
          while (line = socket.gets) && line != "\r\n"; end
          if hop.zero?
            socket.write("HTTP/1.1 302 Found\r\nLocation: /plain\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          else
            socket.write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nSAFE")
          end
          socket.close
        end
      end
      upstream = "http://[::1]:#{server.addr[1]}"
      allow(test_env.config).to receive(:[]).and_call_original
      allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return([upstream])
      expect(Gemstash::HTTPClient.for(Gemstash::Upstream.new(upstream)).get("redirect")).to eq("SAFE")
    rescue Errno::EAFNOSUPPORT, Errno::EADDRNOTAVAIL
      skip "IPv6 loopback unavailable"
    ensure
      socket_thread&.kill
      socket_thread&.join
      server&.close
    end

    it "rejects a malformed Location from a real upstream socket with a gateway error" do
      server = TCPServer.new("127.0.0.1", 0)
      socket_thread = Thread.new do
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"; end
        socket.write("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:#{server.addr[1]}/%ZZ\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close
      end
      client = Gemstash::HTTPClient.for(Gemstash::Upstream.new("http://127.0.0.1:#{server.addr[1]}"))
      expect { client.get("invalid_redirect") }.to raise_error(Gemstash::WebError) {|error| expect(error.code).to eq(502) }
    ensure
      socket_thread&.join
      server&.close
    end

    context "with a redirect away from https" do
      let(:stubs) { Faraday::Adapter::Test::Stubs.new }

      let(:http_client) do
        Gemstash::HTTPClient.for(Gemstash::Upstream.new("https://secure.example.com")).tap do |http_client|
          http_client.client.builder.adapter(:test, stubs)
        end
      end

      it "does not follow a redirect to http" do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["http://plain.example.com"])
        stubs.get("https://secure.example.com/gems/rack") { [302, { "Location" => "http://plain.example.com/rack.gem" }, ""] }
        stubs.get("http://plain.example.com/rack.gem") { raise "The redirect should not have been followed" }

        expect { http_client.get("gems/rack") }.to raise_error do |error|
          expect(error).to be_a(Gemstash::WebError)
          expect(error.message).to eq("Refusing an unlisted upstream redirect")
          expect(error.code).to eq(502)
        end
      end

      it "refuses a redirect to an unlisted https host" do
        stubs.get("https://secure.example.com/gems/rack") { [302, { "Location" => "https://cdn.example.com/rack.gem" }, ""] }
        stubs.get("https://cdn.example.com/rack.gem") { raise "The redirect should not have been followed" }

        expect { http_client.get("gems/rack") }.to raise_error(Gemstash::WebError, "Refusing an unlisted upstream redirect")
      end

      it "accepts a redirect to a listed host" do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["https://cdn.example.com"])
        stubs.get("https://secure.example.com/gems/rack") { [302, { "Location" => "https://cdn.example.com/rack.gem" }, ""] }
        stubs.get("https://cdn.example.com/rack.gem") { [200, {}, "zapatito"] }

        expect(http_client.get("gems/rack")).to eq("zapatito")
      end

      it "refuses redirects outside the listed source path" do
        allow(test_env.config).to receive(:[]).and_call_original
        allow(test_env.config).to receive(:[]).with(:allowed_upstreams).and_return(["https://cdn.example.com/private"])

        ["/private/../secret", "/private/%2e%2e/secret", "/private%2f..%2fsecret"].each do |path|
          expect(Gemstash::Upstream.allowed_redirect?(URI("https://cdn.example.com#{path}"), test_env.config)).to be_falsey
        end
        expect(Gemstash::Upstream.allowed_redirect?(URI("https://cdn.example.com/private/gems/rack.gem"), test_env.config)).to be_truthy
      end

      it "rejects malformed redirect targets as bad gateways" do
        expect do
          Gemstash::HTTPClient.refuse_redirect({ url: URI("https://secure.example.com") }, { url: "http://127.0.0.1:9971/|" })
        end.to raise_error(Gemstash::WebError) {|error| expect(error.code).to eq(502) }
      end
    end

    context "with a url that returns a 500" do
      it "throws an error" do
        expect { http_client.get("error") }.to raise_error do |error|
          expect(error).to be_a(Gemstash::WebError)
          expect(error.message).to eq("Upstream returned HTTP 500")
          expect(error.code).to eq(500)
        end
      end
    end

    context "with a url that returns a 404" do
      it "throws an error" do
        expect { http_client.get("missing") }.to raise_error do |error|
          expect(error).to be_a(Gemstash::WebError)
          expect(error.message).to eq("Upstream returned HTTP 404")
          expect(error.code).to eq(404)
        end
      end
    end

    context "with a stubbed faraday client" do
      let(:stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:faraday_client) { Faraday.new {|builder| builder.adapter(:test, stubs) } }

      context "with a client that specifies a user agent" do
        let(:http_client) do
          Gemstash::HTTPClient.new(faraday_client,
                                   user_agent: "my-agent 6.6.6")
        end

        it "forwards the user agent to the remote server" do
          stubs.get("/gems/rack", "User-Agent" => "my-agent 6.6.6") do
            [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"]
          end
          http_client.get("gems/rack")
          stubs.verify_stubbed_calls
        end
      end

      context "with a simple client" do
        let(:http_client) { Gemstash::HTTPClient.new(faraday_client) }
        let(:default_user_agent) { "Gemstash/#{Gemstash::VERSION}" }

        it "forwards the default user agent to the remote server" do
          stubs.get("/gems/rack", "User-Agent" => default_user_agent) do
            [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"]
          end
          http_client.get("gems/rack")
          stubs.verify_stubbed_calls
        end

        it "handles a connection failed error correctly" do
          stubs.get("/gems/rack", "User-Agent" => default_user_agent) do
            raise Faraday::ConnectionFailed, "https://user:secret@localhost/private?token=secret"
          end
          expect(Gemstash::Logging.logger).to receive(:warn).exactly(3).times.with("Upstream connection failure (Faraday::ConnectionFailed)")
          expect { http_client.get("/gems/rack") }.to raise_error do |error|
            expect(error).to be_a(Gemstash::ConnectionError)
            expect(error.message).to eq("Upstream connection failed")
            expect(error.code).to eq(502)
          end
        end

        it "retries 3 times on connection error" do
          exceptions = [Faraday::ConnectionFailed, Faraday::ConnectionFailed]
          stubs.get("/gems/rack", "User-Agent" => default_user_agent) do
            if exceptions.empty?
              [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"]
            else
              raise exceptions.pop, "I don't like your DNS query!"
            end
          end
          expect(http_client.get("/gems/rack")).to eq("zapatito")
          expect(exceptions).to be_empty
        end

        context "with a block to store the headers" do
          it "throws an error" do
            stubs.get("/gems/rack") { [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"] }

            body_result = nil
            headers_result = nil

            http_client.get("gems/rack") do |body, headers|
              body_result = body
              headers_result = headers
            end

            expect(body_result).to eq("zapatito")
            expect(headers_result).to eq("CONTENT-TYPE" => "octet/stream")
          end
        end
      end
    end

    context "with a slow server" do
      before do
        @slow_server = SlowSimpleServer.new("localhost")
        @slow_server.mount_message("/slow_fetch", "OK")
        @slow_server.start

        @test_env = test_env
      end

      after(:each) do
        @slow_server.stop

        Gemstash::Env.current = @test_env
      end

      it "times out with a small fetch_timeout value" do
        config = Gemstash::Configuration.new(config: { fetch_timeout: 0.1 })
        Gemstash::Env.current = Gemstash::Env.new(config)
        client = Gemstash::HTTPClient.for(Gemstash::Upstream.new(@slow_server.url))
        expect do
          client.get("slow_fetch")
        end.to raise_error(Gemstash::WebError) {|error| expect(error.code).to eq(502) }
      end

      it "does not timeout out with a larger fetch_timeout value" do
        config = Gemstash::Configuration.new(config: { fetch_timeout: 0.5 })
        Gemstash::Env.current = Gemstash::Env.new(config)
        client = Gemstash::HTTPClient.for(Gemstash::Upstream.new(@slow_server.url))
        expect do
          client.get("slow_fetch")
        end.to_not raise_error
      end
    end
  end
end
