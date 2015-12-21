require "sinatra/base"
require "json"
require "gemstash"

module Gemstash
  # Sinatra app which contains Gemstash::Web along with any additional routes
  # from plugins.
  class SinatraApp
    def initialize(gemstash_env)
      @gemstash_env = gemstash_env
    end

    def app
      @app ||= begin
        gemstash_env = @gemstash_env

        Class.new(Sinatra::Base) do
          use Gemstash::WebPrep, gemstash_env: gemstash_env

          gemstash_env.plugins.each do |plugin|
            use plugin.prepended_routes if plugin.respond_to?(:prepended_routes)
          end

          use Gemstash::Web

          gemstash_env.plugins.each do |plugin|
            use plugin.routes if plugin.respond_to?(:routes)
          end
        end
      end
    end
  end

  # This contains the prep work that needs to be done for all routes, including
  # prepended routes.
  class WebPrep < Sinatra::Base
    def initialize(app = nil, gemstash_env: nil)
      @gemstash_env = gemstash_env || Gemstash::Env.new
      Gemstash::Env.current = @gemstash_env
      super(app)
    end

    before do
      Gemstash::Env.current = @gemstash_env
    end
  end

  # This is the main routes for the Gemstash Sinatra app.
  class Web < Sinatra::Base
    def initialize(app = nil, http_client_builder: nil)
      @http_client_builder = http_client_builder || Gemstash::HTTPClient
      super(app)
    end

    before do
      @gem_source = env["gemstash.gem_source"].new(self)
    end

    def http_client_for(server_url)
      @http_client_builder.for(server_url)
    end

    not_found do
      status 404
      body JSON.dump("error" => "Not found", "code" => 404)
    end

    get "/" do
      @gem_source.serve_root
    end

    get "/api/v1/dependencies" do
      @gem_source.serve_dependencies
    end

    get "/api/v1/dependencies.json" do
      @gem_source.serve_dependencies_json
    end

    post "/api/v1/gems" do
      @gem_source.serve_add_gem
    end

    delete "/api/v1/gems/yank" do
      @gem_source.serve_yank
    end

    put "/api/v1/gems/unyank" do
      @gem_source.serve_unyank
    end

    post "/api/v1/add_spec.json" do
      @gem_source.serve_add_spec_json
    end

    post "/api/v1/remove_spec.json" do
      @gem_source.serve_remove_spec_json
    end

    get "/names" do
      @gem_source.serve_names
    end

    get "/versions" do
      @gem_source.serve_versions
    end

    get "/info/:name" do
      @gem_source.serve_info(params[:name])
    end

    get "/quick/Marshal.4.8/:id" do
      @gem_source.serve_marshal(params[:id])
    end

    get "/fetch/actual/gem/:id" do
      @gem_source.serve_actual_gem(params[:id])
    end

    get "/gems/:id" do
      @gem_source.serve_gem(params[:id])
    end

    get "/latest_specs.4.8.gz" do
      @gem_source.serve_latest_specs
    end

    get "/specs.4.8.gz" do
      @gem_source.serve_specs
    end

    get "/prerelease_specs.4.8.gz" do
      @gem_source.serve_prerelease_specs
    end
  end
end
