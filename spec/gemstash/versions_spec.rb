require "spec_helper"

describe Gemstash::Versions do
  let(:upstream) { "https://rubygems.org" }
  let(:http_client) { double }
  let(:web_versions) { Gemstash::Versions.for_upstream(upstream, http_client) }

  def valid_url(url, gem, expected_versions)
    expect(url).to start_with("versions/")
  end

  describe ".fetch" do
    it "finds the gem versions" do
      expect(http_client).to receive(:get) do |url|
        puts "this is the url: #{url}"
        valid_url(url)
      end

      expect(web_versions.fetch).to eq([])
    end
  end
end
