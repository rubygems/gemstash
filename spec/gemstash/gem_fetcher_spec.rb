# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::GemFetcher do
  let(:http_client) { double }
  let(:gem_fetcher) { Gemstash::GemFetcher.new(http_client) }

  describe "#fetch" do
    it "provides the content along with the headers that are kept" do
      headers = { "Content-Length" => "8", "Content-Type" => "octet/stream", "Server" => "nginx" }
      kept_headers = { "content-length" => "8", "content-type" => "octet/stream" }
      expect(http_client).to receive(:get).with("gems/rack-1.0.0.gem").and_yield("zapatito", headers)
      expect {|block| gem_fetcher.fetch("rack-1.0.0.gem", :gem, &block) }.to yield_with_args("zapatito", kept_headers)
    end

    it "fails on an incomplete download" do
      headers = { "Content-Length" => "8" }
      expect(http_client).to receive(:get).with("quick/Marshal.4.8/rack-1.0.0.gemspec.rz").and_yield("zapa", headers)

      expect { gem_fetcher.fetch("rack-1.0.0.gemspec.rz", :spec) { raise "Should not be provided" } }.
        to raise_error(RuntimeError, "Incomplete download, only 4 was downloaded out of 8")
    end
  end
end
