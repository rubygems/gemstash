# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::Upstream do
  it "parses an escaped uri" do
    upstream_uri = Gemstash::Upstream.new("https%3A%2F%2Frubygems.org%2F")
    expect(upstream_uri.to_s).to eq("https://rubygems.org/")
    expect(upstream_uri.host).to eq("rubygems.org")
    expect(upstream_uri.scheme).to eq("https")
    expect(upstream_uri.url("gems")).to eq("https://rubygems.org/gems")
    expect(upstream_uri.user).to be_nil
    expect(upstream_uri.password).to be_nil
  end

  it "parses a clear uri" do
    upstream_uri = Gemstash::Upstream.new("https://rubygems.org/")
    expect(upstream_uri.to_s).to eq("https://rubygems.org/")
    expect(upstream_uri.host).to eq("rubygems.org")
    expect(upstream_uri.scheme).to eq("https")
    expect(upstream_uri.url("gems")).to eq("https://rubygems.org/gems")
    expect(upstream_uri.user).to be_nil
    expect(upstream_uri.password).to be_nil
  end

  it "uses HTTPS schema by default" do
    upstream_uri = Gemstash::Upstream.new("rubygems.org")
    expect(upstream_uri.to_s).to eq("https://rubygems.org")
    expect(upstream_uri.host).to eq("rubygems.org")
    expect(upstream_uri.scheme).to eq("https")
    expect(upstream_uri.url("gems")).to eq("https://rubygems.org/gems")
    expect(upstream_uri.user).to be_nil
    expect(upstream_uri.password).to be_nil
  end

  it "supports user:pass url auth in the uri" do
    upstream_uri = Gemstash::Upstream.new("https://myuser:mypassword@rubygems.org/")
    expect(upstream_uri.user).to eq("myuser")
    expect(upstream_uri.password).to eq("mypassword")
    expect(upstream_uri.auth?).to be_truthy
  end

  it "supports api_key url auth in the uri" do
    upstream_uri = Gemstash::Upstream.new("https://api_key@rubygems.org/")
    expect(upstream_uri.user).to eq("api_key")
    expect(upstream_uri.password).to be_nil
    expect(upstream_uri.auth?).to be_truthy
  end

  it "distinguishes between ports, auths, and paths" do
    upstream_uri = Gemstash::Upstream.new("https://rubygems.org/")
    auth_upstream_uri = Gemstash::Upstream.new("https://myuser:mypassword@rubygems.org/")
    port_upstream_uri = Gemstash::Upstream.new("https://rubygems.org:4321/")
    path_upstream_uri = Gemstash::Upstream.new("https://rubygems.org/custom/path")
    expect(upstream_uri.host_id).to_not eq(auth_upstream_uri.host_id)
    expect(upstream_uri.host_id).to_not eq(port_upstream_uri.host_id)
    expect(upstream_uri.host_id).to_not eq(path_upstream_uri.host_id)
    expect(auth_upstream_uri.host_id).to_not eq(port_upstream_uri.host_id)
    expect(auth_upstream_uri.host_id).to_not eq(path_upstream_uri.host_id)
    expect(port_upstream_uri.host_id).to_not eq(path_upstream_uri.host_id)
  end

  it "stores a bounded credential-free identity for a long source" do
    upstream = Gemstash::Upstream.new("https://client:secret@rubygems.org/#{"x" * 140}")
    expect(upstream.to_s.bytesize).to be < 191
    expect(upstream.cache_uri.bytesize).to be <= 191
    expect(upstream.cache_uri).not_to include("client", "secret")
    expect(Gemstash::Upstream.new("https://other:secret@rubygems.org/#{"x" * 140}").cache_uri).not_to eq(upstream.cache_uri)
  end

  describe "#same_source?" do
    let(:upstream) { Gemstash::Upstream.new("https://rubygems.org") }

    def same_source?(other)
      upstream.same_source?(Gemstash::Upstream.new(other))
    end

    it "ignores trailing slashes, the default port, host casing, escaping, and credentials" do
      %w[
        https://rubygems.org/
        https://rubygems.org:443
        https://RubyGems.org
        rubygems.org
        https%3A%2F%2Frubygems.org%2F
        https://myuser:mypassword@rubygems.org
      ].each do |other|
        expect(same_source?(other)).to be(true), "expected #{other} to be the same source"
      end
    end

    it "distinguishes between schemes, hosts, ports, and paths" do
      %w[
        http://rubygems.org
        http://rubygems.org:443
        https://rubygems.org:4321
        https://rubygems.org/custom/path
        https://rubygems.org?custom=query
        https://rubygems.org.example.com
        https://rubygems.org@example.com
        https://example.com/rubygems.org
      ].each do |other|
        expect(same_source?(other)).to be(false), "expected #{other} to be a different source"
      end
    end
  end

  describe ".allowed_redirect?" do
    let(:config) { Gemstash::Configuration.new(config: { rubygems_url: "http://localhost:9930/private", allowed_upstreams: ["https://cdn.example:444/private"] }) }

    it "accepts an upgrade to HTTPS on the same host and path with the default port" do
      expect(described_class.allowed_redirect?(URI("https://localhost/private/gems/a.gem"), config)).to be(true)
    end

    it "accepts an upgrade to HTTPS on the same explicit port" do
      expect(described_class.allowed_redirect?(URI("https://localhost:9930/private/gems/a.gem"), config)).to be(true)
    end

    it "matches the scheme of an explicitly listed HTTPS source" do
      expect(described_class.allowed_redirect?(URI("http://cdn.example:444/private/a"), config)).to be(false)
    end

    it "rejects redirect targets with userinfo" do
      expect(described_class.allowed_redirect?(URI("https://name@cdn.example:444/private/a"), config)).to be(false)
    end

    it "rejects redirect targets without a hostname" do
      expect(described_class.allowed_redirect?(URI("https:/private/a"), config)).to be(false)
    end

    it "matches the port of an explicitly listed source" do
      expect(described_class.allowed_redirect?(URI("https://cdn.example:445/private/a"), config)).to be(false)
    end

    it "matches the hostname of an explicitly listed source" do
      expect(described_class.allowed_redirect?(URI("https://other.example:444/private/a"), config)).to be(false)
    end

    it "matches the path prefix, not a sibling path" do
      expect(described_class.allowed_redirect?(URI("https://cdn.example:444/elsewhere/a"), config)).to be(false)
    end

    it "accepts an encoded slash in both the configured prefix and redirect target" do
      config = Gemstash::Configuration.new(config: { rubygems_url: "https://cdn.example/gems%2Fprivate" })
      expect(described_class.allowed_redirect?(URI("https://cdn.example/gems%2Fprivate/gems/a.gem"), config)).to be(true)
      expect(described_class.allowed_redirect?(URI("https://cdn.example/gems%2fprivate/gems/a.gem"), config)).to be(true)
      expect(described_class.allowed_redirect?(URI("https://cdn.example/gems%2Fprivate/../secret"), config)).to be(false)
      expect(described_class.allowed_redirect?(URI("https://cdn.example/gems/private/gems/a.gem"), config)).to be(false)
    end

    it "refuses a redirect below a path entry when a segment could resolve to another path" do
      %w[..; ..;x=1 .; %252e%252e ..%5csecret a%00b %2e].each do |segment|
        target = URI("https://cdn.example:444/private/#{segment}/a.gem")
        expect(described_class.allowed_redirect?(target, config)).to be(false), "expected #{segment} to be refused"
      end

      %w[gems a;v=1 sha256:abc rack%2D1.0.0].each do |segment|
        target = URI("https://cdn.example:444/private/#{segment}/a.gem")
        expect(described_class.allowed_redirect?(target, config)).to be(true), "expected #{segment} to be followed"
      end
    end

    it "follows a redirect to an :allowed_redirects entry without making it a source clients can select" do
      config = Gemstash::Configuration.new(config: { allowed_redirects: ["https://cdn.example/gems"] })
      expect(described_class.allowed_redirect?(URI("https://cdn.example/gems/a.gem"), config)).to be(true)
      expect(described_class.allowed_redirect?(URI("https://cdn.example/other/a.gem"), config)).to be(false)
      expect(described_class.new("https://cdn.example/gems").allowed?(config)).to be(false)
    end
  end

  it "supports building urls with parameters" do
    upstream_uri = Gemstash::Upstream.new("https://rubygems.org/")
    expect(upstream_uri.url("gems", "key=value")).to eq("https://rubygems.org/gems?key=value")
  end

  it "has a nil user agent if not provided" do
    expect(Gemstash::Upstream.new("https://rubygems.org/").user_agent).to be_nil
  end

  it "supports getting user agent" do
    expect(Gemstash::Upstream.new("https://rubygems.org/",
                                  user_agent: "my_user_agent").user_agent).to eq("my_user_agent")
  end

  context "with ENV variables for upstream authentication" do
    it "prefers client credentials over configured environment credentials as a pair" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("GEMSTASH_RUBYGEMS__ORG").and_return("server:secret")

      password_source = Gemstash::Upstream.new("https://client:password@rubygems.org/")
      expect([password_source.user, password_source.password]).to eq(%w[client password])

      token_source = Gemstash::Upstream.new("https://TOKEN@rubygems.org/")
      expect([token_source.user, token_source.password]).to eq(["TOKEN", nil])
    end

    context "with user and password" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMSTASH_RUBYGEMS__ORG").and_return("myuser:mypassword")
      end

      it "users user:pass for auth" do
        upstream_uri = Gemstash::Upstream.new("https://rubygems.org/")
        expect(upstream_uri.user).to eq("myuser")
        expect(upstream_uri.password).to eq("mypassword")
        expect(upstream_uri.auth?).to be_truthy
      end
    end

    context "with api key" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("GEMSTASH_RUBYGEMS__ORG").and_return("api_key")
      end

      it "uses api_key for auth" do
        upstream_uri = Gemstash::Upstream.new("https://rubygems.org/")
        expect(upstream_uri.user).to eq("api_key")
        expect(upstream_uri.password).to be_nil
        expect(upstream_uri.auth?).to be_truthy
      end
    end
  end

  describe ".url" do
    let(:server_url) { "https://rubygems.org" }
    let(:upstream) { Gemstash::Upstream.new(server_url) }

    context "with nothing provided" do
      it "returns the server url" do
        expect(upstream.url).to eq("https://rubygems.org")
        expect(upstream.url(nil, "")).to eq("https://rubygems.org")
        expect(upstream.url("", "")).to eq("https://rubygems.org")
      end
    end

    context "with just a query string provided" do
      it "returns the url" do
        expect(upstream.url(nil, "abc=123")).to eq("https://rubygems.org?abc=123")
      end
    end

    context "with just a path provided" do
      it "returns the url" do
        expect(upstream.url("path/somewhere")).to eq("https://rubygems.org/path/somewhere")
      end
    end

    context "with just a path and query string provided" do
      it "returns the url" do
        expect(upstream.url("path/somewhere", "abc=123")).to eq("https://rubygems.org/path/somewhere?abc=123")
      end
    end
  end
end

RSpec.describe Gemstash::Upstream::GemName do
  context "With a simple upstream" do
    let(:upstream) { Gemstash::Upstream.new("https://rubygems.org/") }

    it "resolves to the gem name" do
      expect(Gemstash::Upstream::GemName.new(upstream, "mygemname").to_s).to eq("mygemname")
    end

    it "removes the trailing .gem from the name" do
      gem_name = Gemstash::Upstream::GemName.new(upstream, "mygemname-1.0.1.gem")
      expect(gem_name.id).to eq("mygemname-1.0.1.gem")
      expect(gem_name.name).to eq("mygemname-1.0.1")
    end

    it "removes the trailing .gemspec.rz from the name" do
      gem_name = Gemstash::Upstream::GemName.new(upstream, "mygemname-1.0.1.gemspec.rz")
      expect(gem_name.id).to eq("mygemname-1.0.1.gemspec.rz")
      expect(gem_name.name).to eq("mygemname-1.0.1")
    end
  end
end
