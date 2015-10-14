require "spec_helper"
require "fileutils"

describe "gemstash integration tests" do
  before(:all) do
    speaker_deps = {
      :name => "speaker",
      :number => "0.1.0",
      :platform => "ruby",
      :dependencies => []
    }

    @rubygems_server = SimpleServer.new("127.0.0.1", port: 9043)
    @rubygems_server.mount_gem_deps("speaker", [speaker_deps])
    @rubygems_server.mount_gem("speaker", "0.1.0")
    @rubygems_server.start
    @empty_server = SimpleServer.new("127.0.0.1", port: 9044)
    @empty_server.mount_gem_deps
    @empty_server.start
    @gemstash = TestGemstashServer.new(port: 9042,
                                       config: {
                                         :base_path => TEST_BASE_PATH,
                                         :rubygems_url => @rubygems_server.url
                                       })
    @gemstash.start
    @gemstash_empty_rubygems = TestGemstashServer.new(port: 9041,
                                                      config: {
                                                        :base_path => TEST_BASE_PATH,
                                                        :rubygems_url => @empty_server.url
                                                      })
    @gemstash_empty_rubygems.start
  end

  after(:all) do
    @gemstash.stop
    @gemstash_empty_rubygems.stop
    @rubygems_server.stop
    @empty_server.stop
  end

  describe "bundling install against gemstash" do
    let(:dir) { bundle_path(bundle) }

    after do
      clean_bundle bundle
    end

    context "with upstream gems via a header mirror" do
      let(:bundle) { "integration_spec/header_mirror_gems" }

      # This should stay skipped until bundler sends the X-Gemfile-Source header
      it "successfully bundles" do
        expect(execute("bundle", dir: dir)).to exit_success
        expect(execute("bundle exec speaker hi", dir: dir)).to exit_success.and_output("Hello world\n")
      end
    end
  end
end
