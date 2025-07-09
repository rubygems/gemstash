# frozen_string_literal: true

require "gemstash"

module Gemstash
  module GemSource
    # GemSource for privately stored gems.
    class PrivateSource < Gemstash::GemSource::Base
      include Gemstash::GemSource::DependencyCaching
      include Gemstash::Env::Helper
      attr_accessor :auth

      def self.rack_env_rewriter
        @rack_env_rewriter ||= Gemstash::RackEnvRewriter.new(%r{\A/private})
      end

      def self.matches?(env)
        rewriter = rack_env_rewriter.for(env)
        return false unless rewriter.matches?

        rewriter.rewrite
        true
      end

      def serve_root
        halt 403, "Not yet supported"
      end

      def serve_add_gem
        protected(Gemstash::GemPusher)
      end

      def serve_yank
        protected(Gemstash::GemYanker)
      end

      def serve_add_spec_json
        halt 403, "Not yet supported"
      end

      def serve_remove_spec_json
        halt 403, "Not yet supported"
      end

      def serve_names
        protected(CompactIndexBuilder::Names)
      end

      def serve_versions
        protected(CompactIndexBuilder::Versions)
      end

      def serve_info(name)
        halt(404, { "Content-Type" => "text/plain; charset=utf-8" }, "This gem could not be found") unless DB::Rubygem.where(name: name).limit(1).count > 0

        protected(CompactIndexBuilder::Info, name)
      end

      def serve_marshal(id)
        authorization.protect(self) do
          auth.check("fetch") if gemstash_env.config[:protected_fetch]
          gem_full_name = id.delete_suffix(".gemspec.rz")
          gem = fetch_gem(gem_full_name)
          halt 404 unless gem.exist?(:spec)
          content_type "application/octet-stream"
          gem.content(:spec)
        end
      end

      def serve_actual_gem(id)
        halt 403, "Not yet supported"
      end

      def serve_gem(id)
        authorization.protect(self) do
          auth.check("fetch") if gemstash_env.config[:protected_fetch]
          gem_full_name = id.delete_suffix(".gem")
          gem = fetch_gem(gem_full_name)
          content_type "application/octet-stream"
          gem.content(:gem)
        end
      end

      def serve_specs
        params[:prerelease] = false
        protected(Gemstash::SpecsBuilder)
      end

      def serve_latest_specs
        params[:latest] = true
        protected(Gemstash::SpecsBuilder)
      end

      def serve_prerelease_specs
        params[:prerelease] = true
        protected(Gemstash::SpecsBuilder)
      end

    private

      def protected(servable, ...)
        authorization.protect(self) { servable.serve(self, ...) }
      end

      def authorization
        Gemstash::ApiKeyAuthorization
      end

      def dependencies
        @dependencies ||= Gemstash::Dependencies.for_private
      end

      def storage
        @storage ||= Gemstash::Storage.for("private").for("gems")
      end

      def fetch_gem(gem_full_name)
        gem = storage.resource(gem_full_name)
        halt 404 unless gem.exist?(:gem)
        halt 403, "That gem has been yanked" unless gem.properties[:indexed]
        gem
      end
    end
  end
end
