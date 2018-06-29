require "spec_helper"

describe Gemstash::Versions do
  let(:upstream) { "https://rubygems.org" }
  let(:http_client) { double }
  let(:web_versions) { Gemstash::Versions.for_upstream(upstream, http_client) }

  def valid_url(url)
    expect(url).to start_with("versions/")
  end

  describe ".fetch" do
    context "from cache" do
      let(:cached_versions) do
        <<-VERSIONS
          created_at: 2017-03-27T04:38:13+00:00
          ---
          - 1 05d0116933ba44b0b5d0ee19bfd35ccc
          .cat 0.0.1 631fd60a806eaf5026c86fff3155c289
          0mq 0.1.0,0.1.1,0.1.2,0.2.0,0.2.1,0.3.0,0.4.0,0.4.1,0.5.0,0.5.1,0.5.2,0.5.3 6146193f8f7e944156b0b42ec37bad3e
          0xffffff 0.0.1,0.1.0 0a4a9aeae24152cdb467be02f40482f9
          10to1-crack 0.1.1,0.1.2,0.1.3 e7218e76477e2137355d2e7ded094925"
        VERSIONS
      end

      before do
        Gemstash::Env.current.cache.set_versions("upstream/#{upstream}", cached_versions)
      end

      it "finds the gem versions" do
        expect(web_versions.fetch).to eq(cached_versions)
      end
    end
  end
end
