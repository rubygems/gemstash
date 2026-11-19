# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::Configuration do
  let(:config_dir) { config_path("configuration_spec") }

  context "no config file" do
    let(:env) { Gemstash::Env.new }

    it "loads the default config" do
      expect(env.config[:db_adapter]).to eq("sqlite3")
      expect(env.config.database_connection_config).to match(hash_including(max_connections: 1))
      expect(env.config[:allowed_upstreams]).to eq([])
      expect(env.config[:allowed_redirects]).to eq([])
    end
  end

  context "erb config file" do
    before do
      ENV["DATABASE_URL"] = "postgres://rendered-erb"
    end
    let(:config) { Gemstash::Configuration.new(file: "#{config_dir}/config.yml.erb") }
    let(:env) { Gemstash::Env.new(config) }

    it "interprets the erb, loads yaml and merges with defaults" do
      expect(env.config[:db_adapter]).to eq("postgres")
      expect(env.config[:db_url]).to eq("postgres://rendered-erb")
      expect(env.config.database_connection_config).to match(hash_including(max_connections: 17))
    end
  end

  context "plain yaml config file" do
    let(:config) { Gemstash::Configuration.new(file: "#{config_dir}/config.yml") }
    let(:env) { Gemstash::Env.new(config) }

    it "merges the yaml config with defaults" do
      expect(env.config[:db_adapter]).to eq("postgres")
      expect(env.config[:db_url]).to eq("postgres://gemstash")
    end
  end

  context "empty yaml config file" do
    let(:config) { Gemstash::Configuration.new(file: "#{config_dir}/empty-config.yml") }
    let(:env) { Gemstash::Env.new(config) }

    it "loads the default config" do
      expect(env.config[:db_adapter]).to eq("sqlite3")
    end
  end

  context "config from GEMSTASH_CONFIG environment variable" do
    let(:env) { Gemstash::Env.new }

    before do
      @original_gemstash_config = ENV["GEMSTASH_CONFIG"]
      ENV["GEMSTASH_CONFIG"] = "#{config_dir}/config.yml"
    end

    after do
      ENV.delete("GEMSTASH_CONFIG")
      ENV["GEMSTASH_CONFIG"] = @original_gemstash_config unless @original_gemstash_config.nil?
    end

    it "loads successfully and is merged with defaults" do
      expect(env.config[:db_adapter]).to eq("postgres")
      expect(env.config[:db_url]).to eq("postgres://gemstash")
      expect(env.config[:rubygems_url]).to eq("https://rubygems.org")
    end
  end

  context "with :allowed_upstreams" do
    def load_config(allowed_upstreams)
      Gemstash::Configuration.new(config: { allowed_upstreams: allowed_upstreams })
    end

    it "loads the wildcard, gem source URLs, and an unset value" do
      [
        "*", ["*"], [], nil, "https://my.gem-source.local",
        ["https://user:secret@my.gem-source.local/private/", "my.gem-source.local", "http://127.0.0.1:9292", "*"]
      ].each do |allowed_upstreams|
        expect(load_config(allowed_upstreams)[:allowed_upstreams]).to eq(allowed_upstreams)
      end
    end

    it "refuses an entry that is not a gem source URL, giving its position and not its value" do
      {
        ["https://rubygems.org", "https://user:secret@my.gem-source.local "] => "entry 2 (not a valid URL)",
        ["HTTPS://user:secret@my.gem-source.local"] => "entry 1 (scheme is not http:// or https://)",
        ["*", "https:user:secret@my.gem-source.local"] => "entry 2 (scheme is not followed by //)",
        ["http:/my.gem-source.local"] => "entry 1 (scheme is not followed by //)",
        ["*", "https://user:secret@"] => "entry 2 (no host)",
        [""] => "entry 1 (empty)",
        [nil] => "entry 1 (not a string)",
        8080 => "entry 1 (not a string)"
      }.each do |allowed_upstreams, problem|
        expect { load_config(allowed_upstreams) }.to raise_error(Gemstash::Configuration::InvalidAllowedUpstreamError) do |error|
          expect(error.message).to include(problem)
          expect(error.message).not_to include("secret", "my.gem-source.local")
        end
      end
    end

    it "refuses such an entry in a config file" do
      file = File.join(TEST_BASE_PATH, "allowed_upstreams_config.yml")
      File.write(file, { allowed_upstreams: ["https://my.gem-source.local", "my gem source"] }.to_yaml)
      expect { Gemstash::Configuration.new(file: file) }.
        to raise_error(Gemstash::Configuration::InvalidAllowedUpstreamError, /entry 2 \(not a valid URL\)/)
    end

    it "checks :allowed_redirects in the same way, but without a wildcard" do
      config = Gemstash::Configuration.new(config: { allowed_redirects: ["https://cdn.example/gems"] })
      expect(config[:allowed_redirects]).to eq(["https://cdn.example/gems"])

      expect { Gemstash::Configuration.new(config: { allowed_redirects: ["https://cdn.example", "cdn example"] }) }.
        to raise_error(Gemstash::Configuration::InvalidAllowedUpstreamError, /:allowed_redirects entry 2 \(not a valid URL\)/)
      expect { Gemstash::Configuration.new(config: { allowed_redirects: "*" }) }.
        to raise_error(Gemstash::Configuration::InvalidAllowedUpstreamError, /:allowed_redirects entry 1 \(wildcard is not supported\)/)
    end

    it "does not check the config an env loads on its own, which setup reads before replacing the file" do
      file = File.join(TEST_BASE_PATH, "allowed_upstreams_config.yml")
      File.write(file, { allowed_upstreams: ["my gem source"] }.to_yaml)
      original = ENV["GEMSTASH_CONFIG"]
      ENV["GEMSTASH_CONFIG"] = file
      expect(Gemstash::Env.new.config[:allowed_upstreams]).to eq(["my gem source"])
    ensure
      ENV["GEMSTASH_CONFIG"] = original
    end
  end
end
