require "spec_helper"

describe Gemstash::Env do
  context "with a base path other than default" do
    let(:env) { Gemstash::Env.new }

    it "blocks access if it is not writable" do
      dir = Dir.mktmpdir
      FileUtils.remove_entry dir
      env.config = Gemstash::Configuration.new(config: { :base_path => dir })
      expect { env.base_path }.to raise_error("Base path '#{dir}' is not writable")
      expect { env.base_file("example.txt") }.to raise_error("Base path '#{dir}' is not writable")
    end
  end

  describe "#plugins" do
    let(:env) { Gemstash::Env.new }
    let(:plugin) { double }
    let(:initialized_plugin) { double }

    it "initializes plugins with the environment" do
      Gemstash.register_plugin(plugin)
      expect(plugin).to receive(:new).with(env).and_return(initialized_plugin)
      expect(env.plugins).to match_array([initialized_plugin])
    end

    it "caches the constructed plugins" do
      Gemstash.register_plugin(plugin)
      expect(plugin).to receive(:new).with(env).and_return(initialized_plugin).once
      expect(env.plugins).to match_array([initialized_plugin])
      expect(env.plugins).to match_array([initialized_plugin])
    end
  end
end
