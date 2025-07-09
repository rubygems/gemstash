# frozen_string_literal: true

require "sinatra/base"
require "json"
require "gemstash"

module Gemstash
  # :nodoc:
  class Web < Sinatra::Base
    ruby2_keywords def initialize(options = {})
      raise ArgumentError unless options.is_a?(Hash)

      @gemstash_env = options[:gemstash_env] || Gemstash::Env.new
      @http_client_builder = options[:http_client_builder] || Gemstash::HTTPClient
      Gemstash::Env.current = @gemstash_env
      super()
    end

    before do
      Gemstash::Env.current = @gemstash_env
      @gem_source = env["gemstash.gem_source"].new(self)
    end

    def http_client_for(server_url)
      @http_client_builder.for(server_url)
    end

    not_found do
      status 404
      return body response.body if response.body && !response.body.empty?

      body JSON.dump("error" => "Not found", "code" => 404)
    end

    error GemPusher::ExistingVersionError do
      status 409
      body JSON.dump("error" => "Version already exists", "code" => 409)
    end

    error Gemstash::GemYanker::UnknownGemError, Gemstash::GemYanker::UnknownVersionError do |e|
      status 404
      body JSON.dump("error" => e.message, "code" => 404)
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
