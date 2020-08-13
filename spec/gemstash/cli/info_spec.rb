# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::CLI::Info do
  let(:defaults) do
    default = ""
    Gemstash::Configuration::DEFAULTS.map do |key, value|
      default << "#{key}: #{value}" << "\n"
    end
    default
  end
  let(:with_protected_fetch_true) do
    default = ""
    Gemstash::Configuration::DEFAULTS.map do |key, value|
      if key == :protected_fetch
        default << "#{key}: true" << "\n"
      else
        default << "#{key}: #{value}" << "\n"
      end
    end
    default
  end
  let(:cli) do
    result = double(options: cli_options)
    allow(result).to receive(:set_color) {|x| x }
    result
  end

  let(:cli_options) do
    {
      config_file: File.join(TEST_BASE_PATH, "info_spec_config.yml")
    }
  end

  context "with default setup" do
    # Setup the environment with all default configurations
    before do
      allow(cli).to receive(:ask).and_return("")
      allow(cli).to receive(:yes?).and_return("")
      expect(File.exist?(cli_options[:config_file])).to be_falsey
      # This is expected to touch the metadata file, which we don't want to
      # write out (it would go in ~/.gemstash rather than our test path)
      expect(Gemstash::Storage).to receive(:metadata)
      allow(cli).to receive(:say)
      Gemstash::CLI::Setup.new(cli).run
      expect(File.exist?(cli_options[:config_file])).to be_truthy
    end

    it "saves the config with defaults, then printing only default configs" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.0.0")
      stub_const("Gemstash::VERSION", "1.0.0")
      allow(cli).to receive(:say).with(anything) do |value|
        STDOUT.write value + "\n"
        STDOUT.flush
      end
      expect(File.exist?(cli_options[:config_file])).to be_truthy
      expect { Gemstash::CLI::Info.new(cli).run }.to output(defaults).to_stdout_from_any_process
    end
  end
  context "with manual change in setup" do
    # Setup the environment with protected fetching set to false
    before do
      allow(cli).to receive(:ask).and_return("")
      allow(cli).to receive(:yes?).and_return("")
      allow(cli).to receive(:yes?).with("Use Protected Fetch for Private Gems? [y/N]").and_return("true")
      expect(File.exist?(cli_options[:config_file])).to be_falsey
      # This is expected to touch the metadata file, which we don't want to
      # write out (it would go in ~/.gemstash rather than our test path)
      expect(Gemstash::Storage).to receive(:metadata)
      allow(cli).to receive(:say)
      allow(cli).to receive(:options).with(:redo).and_return(true)
      Gemstash::CLI::Setup.new(cli).run
      expect(File.exist?(cli_options[:config_file])).to be_truthy
    end
    it "saves the config, then printing config with protect fetch sets to true" do
      allow(Gemstash::Storage).to receive(:metadata).and_return(gemstash_version: "1.0.0")
      stub_const("Gemstash::VERSION", "1.0.0")
      allow(cli).to receive(:say).with(anything) do |value|
        STDOUT.write value + "\n"
        STDOUT.flush
      end
      expect { Gemstash::CLI::Info.new(cli).run }.to_not output(defaults).to_stdout_from_any_process
      expect { Gemstash::CLI::Info.new(cli).run }.to output(with_protected_fetch_true).to_stdout_from_any_process
    end
  end
end
