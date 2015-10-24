require "spec_helper"

describe Gemstash::Preload do
  let(:stubs) { stub = Faraday::Adapter::Test::Stubs.new }
  let(:http_client) { Gemstash::HTTPClient.new(Faraday.new {|builder| builder.adapter(:test, stubs) } ) }
  let(:latest_specs) {
    to_marshaled_gzipped_bytes([["latest_gem", "1.0.0", ""]])
  }
  let(:full_specs) {
    to_marshaled_gzipped_bytes([["latest_gem", "1.0.0", ""], ["other", "0.1.0", ""]])
  }

  describe Gemstash::Preload::GemSpecs do
    it "GemSpecs fetches the full specs by default" do
      stubs.get("specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, full_specs]
      end
      specs = Gemstash::Preload::GemSpecs.new(http_client).fetch
      gems = specs.to_a
      expect(gems).not_to be_empty
      expect(gems.first.to_s).to eq("latest_gem-1.0.0")
      expect(gems.last.to_s).to eq("other-0.1.0")
    end

    it "GemSpecs fetches the latest specs when requested" do
      stubs.get("latest_specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, latest_specs]
      end
      specs = Gemstash::Preload::GemSpecs.new(http_client, latest = true).fetch
      expect(specs.to_a.last.to_s).to eq("latest_gem-1.0.0")
    end
  end

  describe Gemstash::Preload::GemPreloader do
    before do
      stubs.get("specs.4.8.gz") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, full_specs]
      end
      stubs.get("gems/latest_gem-1.0.0.gem") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, "The latest gem"]
      end
      stubs.get("gems/other-0.1.0.gem") do
        [200, { "CONTENT-TYPE" => "octet/stream" }, "The other gem"]
      end
    end

    it "Preloads all the gems included in the specs file" do
      preloader = Gemstash::Preload::GemPreloader.new(http_client)
      preloader.preload
      stubs.verify_stubbed_calls
    end
  end

  def to_marshaled_gzipped_bytes(obj)
    buffer = StringIO.new
    gzip = Zlib::GzipWriter.new(buffer)
    gzip.write(Marshal.dump(obj))
    gzip.close
    buffer.string
  end
end
