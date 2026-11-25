# frozen_string_literal: true

require "gemstash"
require "cgi"

module Gemstash
  module GemSource
    # GemSource that purely redirects to the upstream server.
    class RedirectSource < Gemstash::GemSource::Base
      include Gemstash::Env::Helper

      VALID_ID = /\A(?!\.+\z)[A-Za-z0-9._-]+\z/

      def self.rack_env_rewriter
        @rack_env_rewriter ||= Gemstash::RackEnvRewriter.new(%r{\A/redirect/(?<upstream_url>[^/]+)})
      end

      def self.matches?(env)
        rewriter = rack_env_rewriter.for(env)
        return false unless rewriter.matches?

        rewriter.rewrite
        env["gemstash.upstream"] = CGI.unescape(rewriter.captures["upstream_url"])
        capture_user_agent(env)
        true
      end

      def self.capture_user_agent(env)
        env["gemstash.user-agent"] = env["HTTP_USER_AGENT"]
      end

      def redirect(target)
        headers "Cache-Control" => "no-store" if @client_userinfo
        super
      end

      def serve_root
        cache_control :public, :max_age => 31_536_000 unless upstream.uri.userinfo
        redirect redirect_upstream.url(nil, request.query_string)
      end

      def serve_add_gem
        halt 403, "Cannot add gem to an upstream server!"
      end

      def serve_yank
        halt 403, "Cannot yank from an upstream server!"
      end

      def serve_add_spec_json
        halt 403, "Cannot add spec to an upstream server!"
      end

      def serve_remove_spec_json
        halt 403, "Cannot remove spec from an upstream server!"
      end

      def serve_dependencies
        redirect redirect_upstream.url("api/v1/dependencies", request.query_string)
      end

      def serve_dependencies_json
        redirect redirect_upstream.url("api/v1/dependencies.json", request.query_string)
      end

      def serve_names
        redirect redirect_upstream.url("names", request.query_string)
      end

      def serve_versions
        redirect index_upstream.url("versions", request.query_string)
      end

      def serve_info(name)
        upstream
        halt 404 unless VALID_ID.match?(name)
        redirect index_upstream.url("info/#{name}", request.query_string)
      end

      def serve_marshal(id)
        upstream
        halt 404 unless valid_file?(id, ".gemspec.rz")
        redirect redirect_upstream.url("quick/Marshal.4.8/#{id}", request.query_string)
      end

      def serve_actual_gem(id)
        upstream
        halt 404 unless valid_file?(id, ".gem")
        redirect redirect_upstream.url("fetch/actual/gem/#{id}", request.query_string)
      end

      def serve_gem(id)
        upstream
        halt 404 unless valid_file?(id, ".gem")
        redirect redirect_upstream.url("gems/#{id}", request.query_string)
      end

      def serve_latest_specs
        redirect redirect_upstream.url("latest_specs.4.8.gz", request.query_string)
      end

      def serve_specs
        redirect redirect_upstream.url("specs.4.8.gz", request.query_string)
      end

      def serve_prerelease_specs
        redirect redirect_upstream.url("prerelease_specs.4.8.gz", request.query_string)
      end

    private

      def upstream
        @upstream ||= Gemstash::Upstream.new(
          env["gemstash.upstream"],
          user_agent: env["gemstash.user-agent"]
        ).then do |source|
          refuse_upstream(source) unless allowed_upstream?(source)

          @client_userinfo = source.uri.userinfo unless instance_of?(RubygemsSource) &&
            (gemstash_env.config[:ignore_gemfile_source] || env["HTTP_X_GEMFILE_SOURCE"].to_s.empty?)
          configured = [gemstash_env.config[:rubygems_url], *Array(gemstash_env.config[:allowed_upstreams])]
          match = configured.reject {|entry| entry == "*" }.find {|entry| source.same_source?(Gemstash::Upstream.new(entry)) }
          uri = source.uri.dup
          uri.userinfo ||= Gemstash::Upstream.new(match).uri.userinfo if match
          uri.fragment = nil
          lowercase_host(uri)
          Gemstash::Upstream.new(uri, user_agent: source.user_agent)
        end
      rescue URI::InvalidURIError
        raise Gemstash::WebError.new("Invalid upstream source", 502)
      end

      # The allowlist ignores the case of a host, so the cache does as well.
      # Newer uri releases drop the userinfo when the host is set.
      def lowercase_host(uri)
        return unless uri.host.to_s.match?(/[A-Z]/)

        userinfo = uri.userinfo
        uri.host = uri.host.downcase
        uri.userinfo = userinfo
      end

      def redirect_upstream
        upstream
        return upstream if @client_userinfo

        uri = upstream.uri.dup
        uri.user = uri.password = nil
        Gemstash::Upstream.new(uri, user_agent: upstream.user_agent)
      end

      # The default upstream is always allowed, any other one must be listed.
      def allowed_upstream?(upstream)
        upstream.allowed?(gemstash_env.config)
      end

      def valid_file?(id, suffix)
        VALID_ID.match?(id) && id.end_with?(suffix) && id.length > suffix.length
      end

      def refuse_upstream(upstream)
        uri = upstream.uri
        source = "#{uri.scheme}://#{uri.host}:#{uri.port}#{uri.path}"
        log.warn "Refusing upstream #{source.inspect}, it is not in :allowed_upstreams"

        headers "Content-Type" => "text/plain", "Cache-Control" => "no-store"
        halt 403, "This upstream is not allowed by the Gemstash server"
      end

      def index_upstream
        @index_upstream ||=
          if redirect_upstream.uri.host == "rubygems.org"
            uri = redirect_upstream.uri.dup
            # Credentials given for rubygems.org must not go to another host.
            # Older uri releases keep userinfo across #host=, so clear it here.
            uri.user = uri.password = nil
            uri.host = "index.rubygems.org"
            Gemstash::Upstream.new(uri, user_agent: redirect_upstream.user_agent)
          else
            redirect_upstream
          end
      end
    end

    # GemSource for gems in an upstream server.
    class UpstreamSource < Gemstash::GemSource::RedirectSource
      include Gemstash::GemSource::DependencyCaching

      VALID_ID = RedirectSource::VALID_ID

      def self.rack_env_rewriter
        @rack_env_rewriter ||= Gemstash::RackEnvRewriter.new(%r{\A/upstream/(?<upstream_url>[^/]+)})
      end

      def serve_marshal(id)
        serve_cached(id, :spec)
      end

      def serve_gem(id)
        serve_cached(id, :gem)
      end

      def serve_info(name)
        http_client = http_client_for(upstream)
        http_client.get("info/#{name}")
      end

      def serve_versions
        http_client = http_client_for(upstream)
        http_client.get("versions")
      end

      def serve_latest_specs
        serve_index("latest_specs.4.8.gz")
      end

      def serve_prerelease_specs
        serve_index("prerelease_specs.4.8.gz")
      end

      def serve_specs
        serve_index("specs.4.8.gz")
      end

    private

      def serve_index(path)
        index = http_client_for(upstream).get(path)
        content_type "application/octet-stream"
        index
      end

      def serve_cached(id, resource_type)
        upstream
        suffix = resource_type == :gem ? ".gem" : ".gemspec.rz"
        halt 404 unless valid_file?(id, suffix)

        gem = fetch_gem(id, resource_type)
        set_gem_headers(gem, resource_type)
        gem.content(resource_type)
      end

      # The upstream chose the stored content type, so it is never replayed
      def set_gem_headers(gem, resource_type)
        content_type "application/octet-stream"
        return unless gem.property?(:headers, resource_type)

        gem_headers = gem.properties[:headers][resource_type]
        headers["Last-Modified"] = gem_headers["last-modified"] if gem_headers.include?("last-modified")
        headers["ETag"] = gem_headers["etag"] if gem_headers.include?("etag")
      end

      def dependencies
        @dependencies ||= begin
          http_client = http_client_for(upstream)
          Gemstash::Dependencies.for_upstream(upstream, http_client)
        end
      end

      def gem_fetcher
        @gem_fetcher ||= Gemstash::GemFetcher.new(http_client_for(upstream))
      end

      def fetch_gem(id, resource_type)
        gem_name = Gemstash::Upstream::GemName.new(upstream, id)
        storage = Gemstash::Storage.for("gem_cache")
        record = Gemstash::DB::Upstream.find_existing(upstream)
        host_id = record && record.uri == upstream.cache_uri ? record.host_id : upstream.host_id
        gem_resource = storage.for(host_id).resource(gem_name.name)
        gem_resource = configured_cache(gem_name, resource_type, storage) || gem_resource unless gem_resource.exist?(resource_type)
        if gem_resource.exist?(resource_type)
          fetch_local_gem(gem_name, gem_resource, resource_type)
        else
          fetch_remote_gem(gem_name, gem_resource, resource_type)
        end
      end

      def configured_cache(gem_name, resource_type, storage)
        configured = [gemstash_env.config[:rubygems_url], *Array(gemstash_env.config[:allowed_upstreams])]
        configured.each do |entry|
          next if entry == "*"

          source = Gemstash::Upstream.new(entry)
          next if source.to_s == upstream.to_s || source.uri.userinfo != upstream.uri.userinfo
          next unless source.same_source?(upstream) && source.uri.path.sub(%r{/?\z}, "") == upstream.uri.path.sub(%r{/?\z}, "")

          old = Gemstash::DB::Upstream[uri: source.to_s] || Gemstash::DB::Upstream[uri: source.cache_uri]
          next unless old && old.host_id == source.host_id

          resource = storage.for(old.host_id).resource(gem_name.name)
          return resource if resource.exist?(resource_type)
        end
        nil
      end

      def fetch_local_gem(gem_name, gem_resource, resource_type)
        log.info "Gem #{gem_name.name} exists, returning cached #{resource_type}"
        gem_resource
      end

      def fetch_remote_gem(gem_name, gem_resource, resource_type)
        log.info "Gem #{gem_name.name} is not cached, fetching #{resource_type}"
        gem_fetcher.fetch(gem_name.id, resource_type) do |content, properties|
          resource_properties = {
            upstream: upstream.cache_uri,
            gem_name: gem_name.name,
            headers: { resource_type => properties }
          }

          gem = gem_resource.save({ resource_type => content }, resource_properties)
          Gemstash::DB::CachedRubygem.store(upstream, gem_name, resource_type)
          gem
        end
      end
    end

    # GemSource for https://rubygems.org (specifically when defined by using the
    # default upstream).
    class RubygemsSource < Gemstash::GemSource::UpstreamSource
      def self.matches?(env)
        env["gemstash.upstream"] = if env["gemstash.env"].config[:ignore_gemfile_source] || env["HTTP_X_GEMFILE_SOURCE"].to_s.empty?
          env["gemstash.env"].config[:rubygems_url]
        else
          env["HTTP_X_GEMFILE_SOURCE"]
        end

        capture_user_agent(env)
        true
      end
    end
  end
end
