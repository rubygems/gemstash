# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "tempfile"

RSpec.describe Gemstash::HTTPClient do
  before(:all) do
    @server = SimpleServer.new("localhost")
    @other_server = SimpleServer.new("127.0.0.1")
    @server.mount_message("/simple_fetch", "Simple fetch results")
    @server.mount_message("/nested/fetch", "Nested fetch results")
    @server.mount_message("/empty_fetch", "")
    @server.mount_message("/large_fetch", "0123456789" * 10_000)
    @server.mount_message("/error", "Error result", 500)
    @server.mount("/oversized_header") do |_, response|
      response["X-Pad"] = "x" * 100_000
      response.body = "OK"
    end
    @server.mount("/drip") do |_, response|
      response.chunked = true
      response.body = proc do |out|
        10.times do
          out.write("x")
          sleep 0.12
        end
      end
    end
    @server.mount("/small_chunks") do |_, response|
      response.chunked = true
      response.body = proc {|out| 16_384.times { out.write("x" * 1024) } }
    end
    @server.mount("/steady_download") do |_, response|
      response.chunked = true
      response.body = proc do |out|
        6.times do
          out.write("x" * 1024)
          sleep 0.12
        end
      end
    end
    @huge_fetch_sent = huge_fetch_sent = []

    @server.mount("/huge_fetch") do |_, response|
      response.status = 200
      response.chunked = true
      response.body = proc {|out| 10_000.times { huge_fetch_sent << out.write("0123456789" * 1_000) } }
    end

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

    it "rejects oversized headers under the default configuration" do
      expect { http_client.get("oversized_header") }.to raise_error(Gemstash::WebError, "Upstream response headers are too large")
    end

    it "rejects 5,000 short headers and 2,000 informational responses" do
      headers = "X-Padding: xx\r\n" * 5_000
      expect { socket_response("HTTP/1.1 200 OK\r\n#{headers}Content-Length: 0\r\n\r\n") }.to raise_error(Gemstash::WebError, "Upstream response headers are too large")
      interim = "HTTP/1.1 103 Early Hints\r\nX-Pad: x\r\n\r\n" * 2_000
      expect { socket_response("#{interim}HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") }.to raise_error(Gemstash::WebError, "Upstream response headers are too large")
    end

    it "rejects a 70 KiB chunk-size line" do
      chunk = "0" * (70 * 1024)
      expect { socket_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n#{chunk}1\r\na\r\n0\r\n\r\n") }.to raise_error(Gemstash::WebError, "Upstream response headers are too large")
    end

    it "maps a deadline crossing between a socket read and wait to 502" do
      reader, writer = IO.pipe
      allow(reader).to receive(:read_nonblock).and_return(:wait_readable)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      old_limits = Thread.current[:gemstash_http_limits]
      Thread.current[:gemstash_http_limits] = { started: start, grace: 1, bytes: 0, deadline: start + 1 }
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(start, start + 2)
      expect { Net::BufferedIO.new(reader).send(:rbuf_fill) }.to raise_error(Gemstash::WebError) {|error| expect(error.code).to eq(502) }
    ensure
      Thread.current[:gemstash_http_limits] = old_limits
      reader&.close
      writer&.close
    end

    it "rejects a response that finishes after the whole-request deadline" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { max_upstream_duration: 0.01 }))
      response = Struct.new(:status, :body, :headers) do
        def success? = true
      end.new(200, "late", {})
      fake_client = Object.new
      fake_client.define_singleton_method(:get) do |_path, &block|
        request = Struct.new(:headers, :options).new({}, Faraday::RequestOptions.new)
        block.call(request)
        sleep 0.02
        response
      end
      expect { Gemstash::HTTPClient.new(fake_client).get("test") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
    ensure
      Gemstash::Env.current = old_env
    end

    def socket_response(payload)
      server = TCPServer.new("127.0.0.1", 0)
      socket_thread = Thread.new do
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"; end
        socket.write(payload)
        socket.close
      rescue Errno::EPIPE, Errno::ECONNRESET
        socket.close
      end
      Gemstash::HTTPClient.for(Gemstash::Upstream.new("http://127.0.0.1:#{server.addr[1]}")).get("test")
    ensure
      socket_thread&.join
      server&.close
    end

    it "accepts many small chunks within the body cap" do
      expect(http_client.get("small_chunks").bytesize).to eq(16 * 1024 * 1024)
    end

    it "accepts a steady download that takes longer than fetch_timeout" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.3 }))
      expect(http_client.get("steady_download").bytesize).to eq(6 * 1024)
    ensure
      Gemstash::Env.current = old_env
    end

    it "bounds a slow drip by total request time" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { max_upstream_duration: 0.35 }))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { http_client.get("drip") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.9
    ensure
      Gemstash::Env.current = old_env
    end

    it "bounds a one-byte drip even when individual reads do not time out" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.35 }))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { http_client.get("drip") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.9
    ensure
      Gemstash::Env.current = old_env
    end

    it "cuts off a drip within an encrypted TLS record" do
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
      cert.public_key = key.public_key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert.add_extension(OpenSSL::X509::ExtensionFactory.new.tap {|factory| factory.subject_certificate = cert }.create_extension("subjectAltName", "DNS:localhost"))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      cert_file = Tempfile.new("gemstash-tls-cert")
      cert_file.write(cert.to_pem)
      cert_file.flush
      previous_cert_file = ENV.fetch("SSL_CERT_FILE", nil)
      ENV["SSL_CERT_FILE"] = cert_file.path

      origin = TCPServer.new("127.0.0.1", 0)
      proxy = TCPServer.new("127.0.0.1", 0)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = cert
      context.key = key
      tls_server = OpenSSL::SSL::SSLServer.new(origin, context)
      response_ready = Queue.new
      origin_thread = Thread.new do
        socket = tls_server.accept
        while (line = socket.gets) && line != "\r\n"; end
        sleep 0.3
        response_ready << true
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 512\r\nConnection: close\r\n\r\n#{"x" * 512}")
        socket.close
      end
      proxy_thread = Thread.new do
        incoming = proxy.accept
        outgoing = TCPSocket.new("127.0.0.1", origin.addr[1])
        upstream_thread = Thread.new do
          IO.copy_stream(incoming, outgoing)
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE
          nil
        end
        response_started = false
        while (data = outgoing.readpartial(16_384))
          if response_started || !response_ready.empty?
            response_ready.pop unless response_started
            response_started = true
            data.each_byte do |byte|
              incoming.write(byte.chr)
              sleep 0.05
            end
          else
            incoming.write(data)
          end
        end
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
        nil
      ensure
        upstream_thread&.kill
        incoming&.close
        outgoing&.close
      end

      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 2, max_upstream_duration: 4 }))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { Gemstash::HTTPClient.for(Gemstash::Upstream.new("https://localhost:#{proxy.addr[1]}")).get("slow") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 7
    ensure
      Gemstash::Env.current = old_env if old_env
      ENV["SSL_CERT_FILE"] = previous_cert_file
      origin_thread&.kill
      proxy_thread&.kill
      origin_thread&.join
      proxy_thread&.join
      origin&.close
      proxy&.close
      cert_file&.close!
    end

    it "cuts off a drip of chunked trailers, even without a body cap" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.35, max_upstream_bytes: nil }))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { slow_socket_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n", 12, "X-Trail") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
    ensure
      Gemstash::Env.current = old_env
    end

    it "cuts off a drip of header lines" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.35, max_upstream_bytes: nil }))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { slow_socket_response("HTTP/1.1 200 OK\r\n", 12, "X-Line") }.to raise_error(Gemstash::WebError, "Upstream request timed out")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
    ensure
      Gemstash::Env.current = old_env
    end

    it "returns an empty upstream 404 after slowly arriving headers" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.35 }))
      expect { slow_socket_response("HTTP/1.1 404 Not Found\r\n", 4, "X-Line") }.to raise_error(Gemstash::WebError) do |error|
        expect(error.code).to eq(404)
      end
    ensure
      Gemstash::Env.current = old_env
    end

    it "accepts a steady 200 KiB/s download" do
      old_env = test_env
      Gemstash::Env.current = Gemstash::Env.new(Gemstash::Configuration.new(config: { fetch_timeout: 0.35 }))
      expect(slow_socket_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", 160, "body")).to eq("x" * 160 * 1024)
    ensure
      Gemstash::Env.current = old_env
    end

    def slow_socket_response(head, lines, mode)
      server = TCPServer.new("127.0.0.1", 0)
      socket_thread = Thread.new do
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"; end
        socket.write(head)
        lines.times do |index|
          sleep(mode == "body" ? 0.005 : 0.12)
          if mode == "body"
            socket.write("400\r\n#{"x" * 1024}\r\n")
          else
            value = mode == "X-Line" && head.include?("404") ? "x" * 2048 : "x"
            socket.write("#{mode}-#{index}: #{value}\r\n")
          end
        end
        case mode
        when "X-Trail" then socket.write("\r\n")
        when "body" then socket.write("0\r\n\r\n")
        else socket.write("Content-Length: 0\r\n\r\n")
        end
        socket.close
      rescue Errno::EPIPE, Errno::ECONNRESET
        socket.close
      end
      Gemstash::HTTPClient.for(Gemstash::Upstream.new("http://127.0.0.1:#{server.addr[1]}")).get("slow")
    ensure
      socket_thread&.join
      server&.close
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
        end.to raise_error(Gemstash::WebError, "Upstream request timed out") {|error| expect(error.code).to eq(502) }
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

    context "with a :max_upstream_bytes limit" do
      before do
        @test_env = test_env
        config = Gemstash::Configuration.new(config: { max_upstream_bytes: limit,
                                                       allowed_upstreams: [@server.url, @other_server.url] })
        Gemstash::Env.current = Gemstash::Env.new(config)
      end

      after do
        Gemstash::Env.current = @test_env
      end

      context "that the response fits in" do
        let(:limit) { 100_000 }

        it "returns the body of the result" do
          expect(http_client.get("simple_fetch")).to eq("Simple fetch results")
        end

        it "returns a body that is exactly as large as the limit" do
          expect(http_client.get("large_fetch")).to eq("0123456789" * 10_000)
        end

        it "returns an empty body" do
          expect(http_client.get("empty_fetch")).to eq("")
        end

        it "returns only the body of the result after a redirect" do
          expect(http_client.get("redirect")).to eq("Simple fetch results")
          expect(http_client.get("other_redirect")).to eq("Simple fetch results")
        end

        it "keeps the code but not the upstream body of an error" do
          expect { http_client.get("missing") }.to raise_error do |error|
            expect(error).to be_a(Gemstash::WebError)
            expect(error.message).to eq("Upstream returned HTTP 404")
            expect(error.code).to eq(404)
          end
        end

        it "provides the body and headers to a block" do
          http_client.get("simple_fetch") do |body, headers|
            expect(body).to eq("Simple fetch results")
            expect(headers["content-type"]).to eq("text/plain")
          end
        end
      end

      context "that the response exceeds" do
        let(:limit) { 99_999 }

        it "aborts the download" do
          expect { http_client.get("large_fetch") }.to raise_error do |error|
            expect(error).to be_a(Gemstash::WebError)
            expect(error.message).to eq("Upstream response is larger than the 99999 bytes allowed by :max_upstream_bytes")
            expect(error.code).to eq(502)
          end
        end

        it "still returns smaller results" do
          expect(http_client.get("simple_fetch")).to eq("Simple fetch results")
        end

        it "stops reading a response as soon as it is too large" do
          @huge_fetch_sent.clear
          expect { http_client.get("huge_fetch") }.to raise_error(Gemstash::WebError)
          expect(@huge_fetch_sent.sum).to be < 50_000_000
        end
      end

      context "that a redirect exceeds" do
        let(:limit) { 25 }

        it "aborts the download" do
          expect { http_client.get("redirect") }.to raise_error do |error|
            expect(error).to be_a(Gemstash::WebError)
            expect(error.code).to eq(502)
          end
        end
      end

      context "with a client that cannot stream the response" do
        let(:limit) { 7 }
        let(:stubs) { Faraday::Adapter::Test::Stubs.new }
        let(:http_client) { Gemstash::HTTPClient.new(Faraday.new {|builder| builder.adapter(:test, stubs) }) }

        it "rejects a body that is larger than the limit" do
          stubs.get("/gems/rack") { [200, { "CONTENT-TYPE" => "octet/stream" }, "zapatito"] }

          expect { http_client.get("gems/rack") }.to raise_error do |error|
            expect(error).to be_a(Gemstash::WebError)
            expect(error.code).to eq(502)
          end
        end
      end
    end
  end
end
