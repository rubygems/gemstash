require "spec_helper"
require "rack/test"
require "sinatra/base"

describe Gemstash::SinatraApp do
  include Rack::Test::Methods
  let(:env) { Gemstash::Env.new(TEST_CONFIG, db: TEST_DB) }
  let(:app) { Gemstash::SinatraApp.new(env).app }
  let(:upstream) { "https://www.rubygems.org" }
  let(:gem_source) { Gemstash::GemSource::RubygemsSource }

  let(:rack_env) do
    {
      "gemstash.gem_source" => gem_source,
      "gemstash.upstream" => upstream
    }
  end

  context "with a plugin with no routes" do
    let(:plugin_with_no_routes) do
      Class.new do
        def initialize(_)
        end
      end
    end

    before do
      Gemstash.register_plugin(plugin_with_no_routes)
    end

    it "won't cause a failure" do
      get "/", {}, rack_env
      expect(last_response).to redirect_to("https://www.rubygems.org")
    end
  end

  context "with a plugin with routes" do
    let(:plugin_with_routes) do
      Class.new do
        def initialize(_)
        end

        def routes
          Class.new(Sinatra::Base) do
            get "/" do
              "Overridden / results"
            end

            get "/new_route" do
              "New route results"
            end
          end
        end
      end
    end

    before do
      Gemstash.register_plugin(plugin_with_routes)
    end

    it "adds the new routes" do
      get "/new_route", {}, rack_env
      expect(last_response.body).to eq("New route results")
    end

    it "prepares the environment in the new routes" do
      # Expect once for initializer of Gemstash::WebPrep and once for the before filter
      expect(Gemstash::Env).to receive(:current=).with(env).twice
      get "/new_route", {}, rack_env
    end

    it "doesn't override existing routes" do
      get "/", {}, rack_env
      expect(last_response.body).to_not include("Overridden / results")
    end
  end

  context "with a plugin with prepended routes" do
    let(:plugin_with_prepended_routes) do
      Class.new do
        def initialize(_)
        end

        def prepended_routes
          Class.new(Sinatra::Base) do
            get "/" do
              "Overridden / results"
            end

            get "/new_route" do
              "New route results"
            end
          end
        end
      end
    end

    before do
      Gemstash.register_plugin(plugin_with_prepended_routes)
    end

    it "adds the new prepended routes" do
      get "/new_route", {}, rack_env
      expect(last_response.body).to eq("New route results")
    end

    it "prepares the environment in the new routes" do
      # Expect once for initializer of Gemstash::WebPrep and once for the before filter
      expect(Gemstash::Env).to receive(:current=).with(env).twice
      get "/new_route", {}, rack_env
    end

    it "can override existing routes" do
      get "/", {}, rack_env
      expect(last_response.body).to eq("Overridden / results")
    end
  end
end
