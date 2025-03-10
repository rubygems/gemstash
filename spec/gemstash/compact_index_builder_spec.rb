# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::CompactIndexBuilder do
  let(:auth) { Gemstash::ApiKeyAuthorization.new(auth_key) }
  let(:auth_with_invalid_auth_key) { Gemstash::ApiKeyAuthorization.new(invalid_auth_key) }
  let(:auth_without_permission) { Gemstash::ApiKeyAuthorization.new(auth_key_without_permission) }
  let(:auth_key) { "auth-key" }
  let(:invalid_auth_key) { "invalid-auth-key" }
  let(:auth_key_without_permission) { "auth-key-without-permission" }

  before do
    Gemstash::Authorization.authorize(auth_key, "all")
    Gemstash::Authorization.authorize(auth_key_without_permission, ["push"])
    allow(Time).to receive(:now).and_return(Time.new(1990, in: "UTC"))
  end

  context "with no private gems" do
    it "returns empty versions" do
      result = described_class::Versions.new(auth).serve
      expect(result).to eq(<<~VERSIONS)
        created_at: 1990-01-01T00:00:00Z
        ---
      VERSIONS
    end

    it "returns empty names" do
      result = described_class::Names.new(auth).serve
      expect(result).to eq(<<~NAMES)
        ---

      NAMES
    end

    it "returns 404 for info" do
      result = described_class::Info.new(auth, "something").serve
      expect(result).to eq(<<~INFO)
        ---
      INFO
    end
  end

  context "with some private gems" do
    before do
      gem_id = insert_rubygem("example")
      insert_version(gem_id, "0.0.1")
      insert_version(gem_id, "0.0.2")
      insert_version(gem_id, "0.0.2", platform: "java")
      gem_id = insert_rubygem("other-example")
      insert_version(gem_id, "0.1.0")
    end

    it "returns versions" do
      Gemstash::CompactIndexBuilder::Versions.new(auth).serve
      result = Gemstash::CompactIndexBuilder::Versions.new(auth).serve
      expect(result).to eq <<~VERSIONS
        created_at: 1990-01-01T00:00:00Z
        ---
        example 0.0.1 1e6fae87f01f5e16ef83205a1a12646c
        example 0.0.2-java 02fd7dc9130d37b37fb21e7b3c870ada
        example 0.0.2 be6954d4377b5262bee5bf4018e6227f
        other-example 0.1.0 ff0722a59d13124677a2edd0da268bd1
      VERSIONS
    end

    it "returns info" do
      result = Gemstash::CompactIndexBuilder::Info.new(auth, "example").serve
      expect(result).to eq <<~INFO
        ---
        0.0.1 |checksum:786b0634cdc056d7fbb027802bbd6e13a6056143adc69047db6aded595754554
        0.0.2-java |checksum:fd67cdfe89ddbd20e499efccffdc828384acf01e4a3068dbf414150ad7515f5f
        0.0.2 |checksum:bfad311d42610c3d1be9d18064f6e688152560e75c716ff63abb5cbb29673f63
      INFO
    end

    it "returns names" do
      result = Gemstash::CompactIndexBuilder::Names.new(auth).serve
      expect(result).to eq <<~NAMES
        ---
        example
        other-example
      NAMES
    end
  end

  context "with some yanked gems" do
    let(:expected_specs) do
      [["example", Gem::Version.new("0.0.1"), "ruby"],
       ["example", Gem::Version.new("0.0.2"), "ruby"],
       ["example", Gem::Version.new("0.0.2"), "java"],
       ["other-example", Gem::Version.new("0.1.0"), "ruby"]]
    end

    let(:expected_latest_specs) do
      [["example", Gem::Version.new("0.0.2"), "ruby"],
       ["example", Gem::Version.new("0.0.2"), "java"],
       ["other-example", Gem::Version.new("0.1.0"), "ruby"]]
    end

    let(:expected_prerelease_specs) do
      [["example", Gem::Version.new("0.0.2.rc1"), "ruby"],
       ["example", Gem::Version.new("0.0.2.rc2"), "ruby"],
       ["example", Gem::Version.new("0.0.2.rc2"), "java"],
       ["other-example", Gem::Version.new("0.1.1.rc1"), "ruby"]]
    end

    before do
      Gemstash::CompactIndexBuilder::Versions.new(auth).serve
      gem_id = insert_rubygem("example")
      insert_version(gem_id, "0.0.1")
      insert_version(gem_id, "0.0.2.rc1", prerelease: true)
      insert_version(gem_id, "0.0.2.rc2", prerelease: true)
      insert_version(gem_id, "0.0.2.rc2", platform: "java", prerelease: true)
      insert_version(gem_id, "0.0.2")
      insert_version(gem_id, "0.0.2", platform: "java")
      insert_version(gem_id, "0.0.3.rc1", indexed: false, prerelease: true)
      insert_version(gem_id, "0.0.3", indexed: false)
      insert_version(gem_id, "0.0.3.rc1", indexed: false, prerelease: true, platform: "java")
      insert_version(gem_id, "0.0.3", indexed: false, platform: "java")
      gem_id = insert_rubygem("other-example")
      insert_version(gem_id, "0.0.1", indexed: false)
      insert_version(gem_id, "0.0.1.rc1", indexed: false, prerelease: true)
      insert_version(gem_id, "0.1.0")
      insert_version(gem_id, "0.1.1.rc1", prerelease: true)
    end

    it "returns versions" do
      result = Gemstash::CompactIndexBuilder::Versions.new(auth).serve
      expect(result).to eq <<~VERSIONS
        created_at: 1990-01-01T00:00:00Z
        ---
        example 0.0.1 1e6fae87f01f5e16ef83205a1a12646c
        other-example 0.0.1 6105347ebb9825ac754615ca55ff3b0c
        other-example 0.0.1.rc1 6105347ebb9825ac754615ca55ff3b0c
        example 0.0.2-java 30b1ce74f9d06e512e354c697280c5e0
        example 0.0.2 1c60ca76f3375ac0473e16c9920a41c6
        example 0.0.2.rc1 d6f36de1e2fbebb92b6051fc6977ff0a
        example 0.0.2.rc2-java 11850dde5a9df04c3fb2aba44704085d
        example 0.0.2.rc2 48a1807ddf7e6a29c84d0f261cf4df64
        example 0.0.3-java 30b1ce74f9d06e512e354c697280c5e0
        example 0.0.3 30b1ce74f9d06e512e354c697280c5e0
        example 0.0.3.rc1-java 30b1ce74f9d06e512e354c697280c5e0
        example 0.0.3.rc1 30b1ce74f9d06e512e354c697280c5e0
        other-example 0.1.0 ff0722a59d13124677a2edd0da268bd1
        other-example 0.1.1.rc1 1b239fe769f037ab38a4c89ea6b37320
      VERSIONS
    end
  end

  context "with a new spec pushed" do
    before do
      Gemstash::Authorization.authorize(auth_key, "all")
      gem_id = insert_rubygem("example")
      insert_version(gem_id, "0.0.1")
    end

    it "busts the cache" do
      # before
      Gemstash::GemPusher.new(auth, read_gem("example", "0.1.0")).serve
      # after
    end
  end

  context "with a spec yanked" do
    let(:initial_specs) do
      [["example", Gem::Version.new("0.0.1"), "ruby"],
       ["example", Gem::Version.new("0.1.0"), "ruby"]]
    end

    let(:latest_specs) { [["example", Gem::Version.new("0.1.0"), "ruby"]] }

    let(:specs_after_yank) { [["example", Gem::Version.new("0.0.1"), "ruby"]] }

    before do
      Gemstash::Authorization.authorize(auth_key, "all")
      gem_id = insert_rubygem("example")
      insert_version(gem_id, "0.0.1")
      Gemstash::GemPusher.new(auth, read_gem("example", "0.1.0")).serve
    end

    it "busts the cache" do
      result = Gemstash::SpecsBuilder.new(auth).serve
      expect(Marshal.load(gunzip(result))).to match_array(initial_specs)
      Gemstash::GemYanker.new(auth, "example", "0.1.0").serve
      result = Gemstash::SpecsBuilder.new(auth).serve
      expect(Marshal.load(gunzip(result))).to match_array(specs_after_yank)
    end
  end

  context "with protected fetch disabled" do
    it "serves versions without authorization" do
      result = Gemstash::CompactIndexBuilder::Versions.new(auth).serve
      expect(result).to eq(<<~VERSIONS)
        created_at: 1990-01-01T00:00:00Z
        ---
      VERSIONS
    end
  end

  xcontext "with protected fetch enabled" do
    before do
      @test_env = test_env
      config = Gemstash::Configuration.new(config: { protected_fetch: true })
      Gemstash::Env.current = Gemstash::Env.new(config)
    end

    after do
      Gemstash::Env.current = @test_env
    end

    context "with valid authorization" do
      it "serves specs" do
        result = Gemstash::SpecsBuilder.new(auth).serve
        expect(Marshal.load(gunzip(result))).to eq([])
      end
    end

    context "with invalid authorization" do
      it "prevents serving specs" do
        expect { Gemstash::SpecsBuilder.new(auth_with_invalid_auth_key).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
      end
    end

    context "with invalid permission" do
      it "prevents serving specs" do
        expect { Gemstash::SpecsBuilder.new(auth_without_permission).serve }.
          to raise_error(Gemstash::NotAuthorizedError)
      end
    end
  end
end
