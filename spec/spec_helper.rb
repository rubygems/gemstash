# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
ENV["RACK_ENV"] = "test"
require "aruba/rspec"
require "gemstash"
require "dalli"
require "fileutils"
require "pathname"
require "support/db_helpers"
require "support/env_helpers"
require "support/exec_helpers"
require "support/file_helpers"
require "support/in_process_exec"
require "support/log_helpers"
require "support/matchers"
require "support/simple_server"
require "support/slow_simple_server"
require "support/test_gemstash_server"
require "support/s3_helpers"
require "vcr"
require "yaml"

TEST_BASE_PATH = File.expand_path("../tmp/test_base", __dir__)
TEST_CONFIG_PATH = File.expand_path("../tmp/test_base/config.yml", __dir__)
FileUtils.mkpath(TEST_BASE_PATH) unless Dir.exist?(TEST_BASE_PATH)
Pathname.new(TEST_BASE_PATH).children.each do |path|
  next if path.to_s == TEST_CONFIG_PATH

  path.rmtree
end
config_yaml_file = YAML.load_file TEST_CONFIG_PATH
config_yaml_file[:base_path] = TEST_BASE_PATH
File.write(TEST_CONFIG_PATH, config_yaml_file.to_yaml)
TEST_LOG_FILE = File.join(TEST_BASE_PATH, "server.log")
TEST_CONFIG = Gemstash::Configuration.new(file: TEST_CONFIG_PATH)
Gemstash::Env.current = Gemstash::Env.new(TEST_CONFIG)
Thread.current[:test_gemstash_env_set] = true
TEST_DB = Gemstash::Env.current.db
Sequel::Model.db = TEST_DB

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.around(:each) do |example|
    test_env.config = TEST_CONFIG unless test_env.config == TEST_CONFIG

    # Some integration specs will fail in a transaction, so allow disabling
    if example.metadata[:db_transaction] == false
      example.run
    else
      TEST_DB.transaction(:rollback => :always) do
        example.run
      end
    end

    TEST_DB.disconnect

    # If a spec has no transaction, delete the DB, and force recreate/migrate to ensure it is clean
    if example.metadata[:db_transaction] == false
      File.delete(File.join(TEST_BASE_PATH, "gemstash.db"))
      Gemstash::Env.migrate(TEST_DB)
    end
  end

  config.before(:each) do
    test_env.cache_client.flush
    Gemstash::Logging.reset

    Pathname.new(TEST_BASE_PATH).children.each do |path|
      next if path.basename.to_s.end_with?(".db")
      next if path.to_s == TEST_CONFIG_PATH

      path.rmtree
    end

    Gemstash::Logging.setup_logger(TEST_LOG_FILE)
  end

  config.after(:suite) do
    SimpleServer.join_all
    TestGemstashServer.join_all
  end

  # Tag examples with focus: true to run only those
  config.filter_run :focus
  config.run_all_when_everything_filtered = true

  config.include S3Helpers
  config.include EnvHelpers
  config.include DBHelpers
  config.include ExecHelpers
  config.include FileHelpers
  config.include LogHelpers
  config.raise_errors_for_deprecations!

  VCR.configure do |vcr_config|
    vcr_config.cassette_library_dir = "fixtures/vcr_cassettes"
    vcr_config.hook_into :webmock
    vcr_config.configure_rspec_metadata!
    vcr_config.filter_sensitive_data("<REDACTED_ACCESS_KEY>") { config_yaml_file[:aws_access_key_id] }
    vcr_config.filter_sensitive_data("<REDACTED_SECRET_ACCESS_KEY>") { config_yaml_file[:aws_secret_access_key] }
    vcr_config.filter_sensitive_data("<REDACTED_BUCKET_NAME>") { config_yaml_file[:bucket_name] }
    vcr_config.filter_sensitive_data("<REDACTED_REGION_NAME>") { config_yaml_file[:region] }
    vcr_config.allow_http_connections_when_no_cassette = true
  end
end
