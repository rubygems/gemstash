# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::CLI::Info do
  let(:default_config) do
    {
      cache_type: "memory",
      base_path: File.expand_path("~/.gemstash").to_s,
      db_adapter: "sqlite3",
      bind: "tcp://0.0.0.0:9292",
      rubygems_url: "https://rubygems.org",
      ignore_gemfile_source: false,
      protected_fetch: false,
      fetch_timeout: 20,
      db_connection_options: {},
      puma_threads: 16,
      puma_workers: 1,
      cache_expiration: 1800,
      cache_max_size: 500
    }
  end

  let(:cli) do
    result = double(options: cli_options)
    allow(result).to receive(:set_color) {|x| x }
    result
  end

  before do
    @test_env = test_env
    Gemstash::Env.current = Gemstash::Env.new(TEST_CONFIG)
    Gemstash::Configuration::DEFAULTS.merge(base_path: TEST_BASE_PATH)
    stub_const("Gemstash::Configuration::DEFAULTS", default_config)
    config_file_path = File.join(TEST_BASE_PATH, "info_spec_config.yml")
    File.open(config_file_path, "w+") {|f| f.write(default_config.to_yaml) }
  end

  after do
    Gemstash::Env.current = @test_env
  end

  let(:cli_options) do
    {
      config_file: File.join(TEST_BASE_PATH, "info_spec_config.yml")
    }
  end

  it "Prints the current current Gemstash configuration" do
    expected_output = +""
    default_config.keys.map {|k| expected_output << "#{k}: #{default_config[k]}\n" }
    expect(Gemstash::CLI::Info.new(cli).run).to eq(expected_output)
  end
end
