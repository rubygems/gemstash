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
        halt 403, "Not yet supported"
      end

      def serve_versions
        halt 403, "Not yet supported"
      end

      def serve_gem_versions(name)
        authorization.protect(self) do
          auth.check("fetch") if gemstash_env.config[:protected_fetch]
          name.slice! ".json"
          gem = fetch_gem(name)
          halt 404 unless gem.exist?(:spec)
          content_type "application/json;charset=UTF-8"
          fetch_gem_versions(name).to_json
        end
      end

      def serve_info(name)
        halt 403, "Not yet supported"
      end

      def serve_marshal(id)
        authorization.protect(self) do
          auth.check("fetch") if gemstash_env.config[:protected_fetch]
          gem_full_name = id.sub(/\.gemspec\.rz\z/, "")
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
          gem_full_name = id.sub(/\.gem\z/, "")
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

      def protected(servable)
        authorization.protect(self) { servable.serve(self) }
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

      def fetch_gem_versions(gem)
        results = db["
          SELECT rubygem.name,
                 version.number, version.platform
          FROM rubygems rubygem
          JOIN versions version
            ON version.rubygem_id = rubygem.id
          WHERE rubygem.name = ?
            AND version.indexed = ?", gem.to_a, true].to_a
        results.group_by {|r| r[:name] }.each do |rows|
          requirements = rows.group_by {|r| [r[:number], r[:platform]] }

          value = requirements.map do |(version, platform)|
            {
              :number => version,
              :platform => platform
            }
          end

          yield(gem, value)
        end
      end
    end
  end
end
