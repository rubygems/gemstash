# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::Dependencies do
  let(:upstream) { "https://rubygems.org" }
  let(:http_client) { double }
  let(:web_deps) { Gemstash::Dependencies.for_upstream(upstream, http_client) }
  let(:db_deps) { Gemstash::Dependencies.for_private }

  def valid_url(url, expected_gems)
    expect(url).to start_with("api/v1/dependencies.json?gems=")
    params = url.sub("api/v1/dependencies.json?gems=", "")
    expect(params.split(",")).to match_array(expected_gems)
  end

  describe ".fetch" do
    context "one gem" do
      it "finds the gem" do
        result = [{
          :name => "foo",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }]

        expect(http_client).to receive(:get) {|url|
          valid_url(url, %w[foo])
          JSON.dump(result)
        }

        expect(web_deps.fetch(%w[foo])).to eq(result)
      end
    end

    context "multiple gems" do
      it "finds the gems" do
        result = [{
          :name => "foo",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }, {
          :name => "bar",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }]

        expect(http_client).to receive(:get) {|url|
          valid_url(url, %w[foo bar])
          JSON.dump(result)
        }

        expect(web_deps.fetch(%w[foo bar])).to match_dependencies(result)
      end
    end

    context "some missing gems" do
      it "finds the available gems" do
        result = [{
          :name => "foo",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }, {
          :name => "bar",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }]

        expect(http_client).to receive(:get) {|url|
          valid_url(url, %w[foo bar baz])
          JSON.dump(result)
        }

        expect(web_deps.fetch(%w[foo bar baz])).to match_dependencies(result)
      end
    end

    context "multiple similar requests" do
      it "caches the results" do
        foo = {
          :name => "foo",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }

        bar = {
          :name => "bar",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => []
        }

        expect(http_client).to receive(:get) {|url|
          valid_url(url, %w[foo bar baz])
          JSON.dump([foo, bar])
        }.once

        expect(web_deps.fetch(%w[foo bar baz])).to match_dependencies([foo, bar])
        expect(web_deps.fetch(%w[baz foo bar])).to match_dependencies([foo, bar])
        expect(web_deps.fetch(%w[foo])).to match_dependencies([foo])
        expect(web_deps.fetch(%w[bar])).to match_dependencies([bar])
        expect(web_deps.fetch(%w[baz])).to match_dependencies([])
      end
    end

    context "with an upstream that does not follow the dependency API" do
      let(:foo) do
        {
          :name => "foo",
          :number => "1.0.0",
          :platform => "ruby",
          :dependencies => [["bar", ">= 1.0"]]
        }
      end

      def fetch_with_response(body, gems = %w[foo])
        allow(http_client).to receive(:get).and_return(body)
        web_deps.fetch(gems)
      end

      it "only keeps the fields of the dependency API" do
        result = fetch_with_response(JSON.dump([foo.merge(:extra => { "nested" => [1, 2] })]))
        expect(result).to eq([foo])
      end

      it "ignores and does not cache gems that were not requested" do
        other = foo.merge(:name => "other")
        expect(fetch_with_response(JSON.dump([foo, other]))).to eq([foo])
        expect(http_client).to receive(:get).and_return(JSON.dump([]))
        expect(web_deps.fetch(%w[other])).to eq([])
      end

      it "rejects a response that is not valid JSON" do
        expect { fetch_with_response(Marshal.dump([foo])) }.to raise_error(Gemstash::WebError) do |error|
          expect(error.code).to eq(502)
        end
      end

      it "rejects a response that is not a list of dependencies" do
        [
          { :foo => foo },
          "foo",
          nil,
          [1, 2],
          [["foo", "1.0.0"]],
          [foo.merge(:name => nil)],
          [foo.merge(:name => { "a" => 1 })],
          [foo.merge(:number => 1.0)],
          [foo.reject {|key, _| key == :platform }],
          [foo.merge(:dependencies => "bar")],
          [foo.merge(:dependencies => [["bar"]])],
          [foo.merge(:dependencies => [["bar", ">= 1.0", "extra"]])],
          [foo.merge(:dependencies => [["bar", 1]])],
          [foo.merge(:dependencies => [{ "bar" => ">= 1.0" }])]
        ].each do |response|
          expect { fetch_with_response(JSON.dump(response)) }.
            to raise_error(Gemstash::WebError), "expected #{response.inspect} to be rejected"
        end
      end

      it "does not cache anything from a rejected response" do
        expect { fetch_with_response(JSON.dump([foo, foo.merge(:number => 2)])) }.to raise_error(Gemstash::WebError)
        expect(fetch_with_response(JSON.dump([foo]))).to eq([foo])
      end
    end

    context "with private gem requests" do
      before do
        gem_id = insert_rubygem "custom"
        version_id = insert_version gem_id, "0.0.1"
        insert_dependency version_id, "foo", "~> 1.0"
      end

      it "finds the available gems" do
        custom = {
          :name => "custom",
          :number => "0.0.1",
          :platform => "ruby",
          :dependencies => [["foo", "~> 1.0"]]
        }

        expect(db_deps.fetch(%w[foo bar baz custom])).to match_dependencies([custom])
      end
    end

    context "with multiple private gem requests" do
      before do
        gem1_id = insert_rubygem "custom1"
        gem2_id = insert_rubygem "custom2"
        version1_id = insert_version gem1_id, "0.0.1"
        insert_version gem2_id, "0.2.0"
        version2_id = insert_version gem1_id, "0.2.1"
        insert_dependency version1_id, "foo", "~> 1.0"
        insert_dependency version2_id, "foo", "~> 1.1"
        insert_dependency version1_id, "bar", ">= 0.9"
      end

      def dependency_item(results, name, number)
        results.find {|x| x[:name] == name && x[:number] == number }
      end

      it "finds the available gems" do
        custom1_0_0_1 = {
          :name => "custom1",
          :number => "0.0.1",
          :platform => "ruby",
          :dependencies => [["foo", "~> 1.0"],
                            ["bar", ">= 0.9"]]
        }

        custom1_0_2_1 = {
          :name => "custom1",
          :number => "0.2.1",
          :platform => "ruby",
          :dependencies => [["foo", "~> 1.1"]]
        }

        custom_2 = {
          :name => "custom2",
          :number => "0.2.0",
          :platform => "ruby",
          :dependencies => []
        }

        expect(db_deps.fetch(%w[custom1 custom2])).
          to match_dependencies([custom1_0_0_1, custom1_0_2_1, custom_2])
      end
    end
  end
end
