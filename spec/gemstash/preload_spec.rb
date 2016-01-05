require "spec_helper"

describe Gemstash::Preload do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:http_client) { Gemstash::HTTPClient.new(Faraday.new {|builder| builder.adapter(:test, stubs) }) }
  let(:latest_specs) do
    gzip(Marshal.dump([["latest_gem", "1.0.0", "ruby"]]))
  end
  let(:prerelease_specs) do
    gzip(Marshal.dump([["prerelease_gem", "0.9.0", "ruby"]]))
  end
  let(:full_specs) do
    gzip(Marshal.dump([["latest_gem", "1.0.0", "ruby"], ["other", "0.1.0", "ruby"]]))
  end

  describe Gemstash::Preload::GemSpecFilename do
    it "fails when both latest and prerelease is set to true" do
      expect { Gemstash::Preload::GemSpecFilename.new(prerelease: true, latest: true) }.to raise_error(
        /It makes no sense to ask for latest and prerelease, pick only one/)
    end

    it "returns the default spec file by default" do
      expect(Gemstash::Preload::GemSpecFilename.new.to_s).to eq("specs.4.8.gz")
    end

    it "returns the prerelease spec file with prerelease: true" do
      expect(Gemstash::Preload::GemSpecFilename.new(prerelease: true).to_s).to eq("prerelease_specs.4.8.gz")
    end

    it "returns the latest spec file with latest: true" do
      expect(Gemstash::Preload::GemSpecFilename.new(latest: true).to_s).to eq("latest_specs.4.8.gz")
    end
  end

  describe Gemstash::Preload::GemSpecs do
    let(:latest) { Gemstash::Preload::GemSpecFilename.new(latest: true) }
    let(:prerelease) { Gemstash::Preload::GemSpecFilename.new(prerelease: true) }

    it "GemSpecs fetches the full specs by default" do
      stubs.get("specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, full_specs]
      end
      specs = Gemstash::Preload::GemSpecs.new(http_client).fetch
      expect(specs).not_to be_empty
      expect(specs.first.to_s).to eq("latest_gem-1.0.0")
      expect(specs.last.to_s).to eq("other-0.1.0")
    end

    it "fetches the latest specs when requested" do
      stubs.get("latest_specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, latest_specs]
      end
      specs = Gemstash::Preload::GemSpecs.new(http_client, latest).fetch
      expect(specs.last.to_s).to eq("latest_gem-1.0.0")
    end

    it "fetches the prerelease specs when requested" do
      stubs.get("prerelease_specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, prerelease_specs]
      end
      specs = Gemstash::Preload::GemSpecs.new(http_client, prerelease).fetch
      expect(specs.last.to_s).to eq("prerelease_gem-0.9.0")
    end
  end

  describe Gemstash::Preload::GemPreloader do
    before do
      stubs.get("specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, full_specs]
      end
      stubs.head("gems/latest_gem-1.0.0.gem") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, "The latest gem"]
      end
      stubs.head("gems/other-0.1.0.gem") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, "The other gem"]
      end
    end

    let(:out) { StringIO.new }

    it "Preloads all the gems included in the specs file" do
      Gemstash::Preload::GemPreloader.new(http_client, out: out).preload
      stubs.verify_stubbed_calls
    end

    it "Skips gems as requested" do
      Gemstash::Preload::GemPreloader.new(http_client, { skip: 1 }, out: out).preload
      expect(out.string).to eq("\r2/2")
    end

    it "Loads as many gems as requested" do
      Gemstash::Preload::GemPreloader.new(http_client, { limit: 1 }, out: out).preload
      expect(out.string).to eq("\r1/2")
    end

    it "Loads only the last gem when requested" do
      Gemstash::Preload::GemPreloader.new(http_client, { skip: 1, limit: 1 }, out: out).preload
      expect(out.string).to eq("\r2/2")
    end

    it "Loads no gem at all when the skip is larger than the size" do
      Gemstash::Preload::GemPreloader.new(http_client, { skip: 3 }, out: out).preload
      expect(out.string).to be_empty
    end

    it "Loads no gem at all when the limit is zero" do
      Gemstash::Preload::GemPreloader.new(http_client, { limit: 0 }, out: out).preload
      expect(out.string).to be_empty
    end

    it "Loads in order when using only one thread" do
      Gemstash::Preload::GemPreloader.new(http_client, { threads: 1 }, out: out).preload
      expect(out.string).to eq("\r1/2\r2/2")
    end
  end
end
