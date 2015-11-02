require "spec_helper"
require "fileutils"

describe "gemstash integration tests" do
  before(:all) do
    speaker_deps = [
      {
        :name => "speaker",
        :number => "0.1.0",
        :platform => "ruby",
        :dependencies => []
      }, {
        :name => "speaker",
        :number => "0.1.0",
        :platform => "java",
        :dependencies => []
      }, {
        :name => "speaker",
        :number => "0.2.0.pre",
        :platform => "ruby",
        :dependencies => []
      }, {
        :name => "speaker",
        :number => "0.2.0.pre",
        :platform => "java",
        :dependencies => []
      }
    ]

    speaker_specs = [["speaker", Gem::Version.new("0.1.0"), "ruby"],
                     ["speaker", Gem::Version.new("0.1.0"), "java"]]
    speaker_prerelease_specs = [["speaker", Gem::Version.new("0.2.0.pre"), "ruby"],
                                ["speaker", Gem::Version.new("0.2.0.pre"), "java"]]
    @rubygems_server = SimpleServer.new("127.0.0.1", port: 9043)
    @rubygems_server.mount_gem_deps("speaker", speaker_deps)
    @rubygems_server.mount_gem("speaker", "0.1.0")
    @rubygems_server.mount_gem("speaker", "0.1.0-java")
    @rubygems_server.mount_gem("speaker", "0.2.0.pre")
    @rubygems_server.mount_gem("speaker", "0.2.0.pre-java")
    @rubygems_server.mount_quick_marshal("speaker", "0.1.0")
    @rubygems_server.mount_quick_marshal("speaker", "0.1.0-java")
    @rubygems_server.mount_quick_marshal("speaker", "0.2.0.pre")
    @rubygems_server.mount_quick_marshal("speaker", "0.2.0.pre-java")
    @rubygems_server.mount_specs_marshal_gz(speaker_specs)
    @rubygems_server.mount_prerelease_specs_marshal_gz(speaker_prerelease_specs)
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

  describe "bundle install against gemstash" do
    let(:dir) { bundle_path(bundle) }

    let(:platform_message) do
      if RUBY_PLATFORM == "java"
        "Java"
      else
        "Ruby"
      end
    end

    after do
      clean_bundle bundle
    end

    context "with upstream gems via a header mirror" do
      let(:bundle) { "integration_spec/header_mirror_gems" }

      it "successfully bundles" do
        expect(execute("bundle", dir: dir)).to exit_success
        expect(execute("bundle exec speaker hi", dir: dir)).
          to exit_success.and_output("Hello world, #{platform_message}\n")
      end

      it "can bundle with full index" do
        expect(execute("bundle --full-index", dir: dir)).to exit_success
        expect(execute("bundle exec speaker hi", dir: dir)).
          to exit_success.and_output("Hello world, #{platform_message}\n")
      end

      it "can bundle with prerelease versions" do
        env = { "SPEAKER_VERSION" => "= 0.2.0.pre" }
        expect(execute("bundle", dir: dir, env: env)).to exit_success
        expect(execute("bundle exec speaker hi", dir: dir, env: env)).
          to exit_success.and_output("Hello world, pre, #{platform_message}\n")
      end

      it "can bundle with prerelease versions with full index" do
        env = { "SPEAKER_VERSION" => "= 0.2.0.pre" }
        expect(execute("bundle --full-index", dir: dir, env: env)).to exit_success
        expect(execute("bundle exec speaker hi", dir: dir, env: env)).
          to exit_success.and_output("Hello world, pre, #{platform_message}\n")
      end
    end
  end
end
