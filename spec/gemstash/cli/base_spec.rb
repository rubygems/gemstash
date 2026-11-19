# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::CLI::Base do
  let(:cli) do
    result = double(say: nil)
    allow(result).to receive(:set_color) {|x| x }
    result
  end

  before do
    # Don't actually allow the env to be updated
    allow(Gemstash::Env).to receive(:current=)
  end

  describe "#check_gemstash_version" do
    let(:base) { Gemstash::CLI::Base.new(cli) }

    it "allows loading when stored metadata is the same version" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.0.0")
      stub_const("Gemstash::VERSION", "1.0.0")
      base.send(:check_gemstash_version)
    end

    it "allows loading when stored metadata is prerelease of the same version" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.0.0.pre.1")
      stub_const("Gemstash::VERSION", "1.0.0")
      base.send(:check_gemstash_version)
    end

    it "blocks loading when this version is a prerelease of the stored metadata version" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.0.0")
      stub_const("Gemstash::VERSION", "1.0.0.pre.1")
      expect { base.send(:check_gemstash_version) }.to raise_error(Gemstash::CLI::Error, /does not support version/)
    end

    it "allows loading when stored metadata is older" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "0.1.0")
      stub_const("Gemstash::VERSION", "1.0.0")
      base.send(:check_gemstash_version)
    end

    it "allows loading when stored metadata is prerelease of an older version" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "0.1.0.pre.1")
      stub_const("Gemstash::VERSION", "1.0.0")
      base.send(:check_gemstash_version)
    end

    it "blocks loading when stored metadata is newer" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.1.0")
      stub_const("Gemstash::VERSION", "1.0.0")
      expect { base.send(:check_gemstash_version) }.to raise_error(Gemstash::CLI::Error, /does not support version/)
    end

    it "blocks loading when stored metadata is prerelease of a newer version" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.1.0.pre.1")
      stub_const("Gemstash::VERSION", "1.0.0")
      expect { base.send(:check_gemstash_version) }.to raise_error(Gemstash::CLI::Error, /does not support version/)
    end
  end

  describe "#store_config" do
    let(:base) { Gemstash::CLI::Base.new(cli) }

    it "fails if the config file doesn't exist" do
      allow(cli).to receive(:options).and_return(config_file: File.join(TEST_BASE_PATH, "missing_file.yml"))
      expect { base.send(:store_config) }.to raise_error(Gemstash::CLI::Error, /missing_file\.yml/)
    end

    it "fails if the config file is specified as empty" do
      allow(cli).to receive(:options).and_return(config_file: "")
      expect { base.send(:store_config) }.to raise_error(Gemstash::CLI::Error, /Missing config file/)
    end

    it "fails to start if the config file has an :allowed_upstreams entry that is not a gem source URL" do
      config_file = File.join(TEST_BASE_PATH, "bad_allowed_upstreams.yml")
      File.write(config_file, { allowed_upstreams: ["https://user:secret@my.gem-source.local "] }.to_yaml)
      allow(cli).to receive(:options).and_return(config_file: config_file)
      start = Gemstash::CLI::Start.new(cli)
      expect { start.send(:store_config) }.to raise_error(Gemstash::CLI::Error, /Invalid :allowed_upstreams entry 1/) do |error|
        expect(error.message).not_to include("secret")
      end
    end

    it "loads such a config file for the commands that do not start the server" do
      config_file = File.join(TEST_BASE_PATH, "bad_allowed_upstreams.yml")
      File.write(config_file, { allowed_upstreams: ["https://my.gem-source.local "] }.to_yaml)
      allow(cli).to receive(:options).and_return(config_file: config_file)
      expect(Gemstash::Env.current).to receive(:config=) {|config| expect(config[:allowed_upstreams]).to eq(["https://my.gem-source.local "]) }
      base.send(:store_config)
    end
  end
end
