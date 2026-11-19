# frozen_string_literal: true

require "cgi"
require "digest"
require "forwardable"
require "uri"

module Gemstash
  # :nodoc:
  class Upstream
    extend Forwardable

    attr_reader :user_agent, :uri

    def_delegators :@uri, :scheme, :host, :to_s

    def initialize(upstream, user_agent: nil)
      if upstream.is_a?(URI::Generic)
        @uri = upstream.dup
      else
        url = upstream.to_s
        url = CGI.unescape(url) if url.match?(/\Ahttps?%3A%2F%2F/i)
        url = "https://#{url}" unless %r{^https?://}.match?(url)
        @uri = URI(url)
      end
      @user_agent = user_agent
      raise "URL '#{@uri}' is not valid!" unless @uri.to_s.match?(URI::DEFAULT_PARSER.make_regexp)
    end

    def url(path = nil, params = nil)
      base = to_s

      unless path.to_s.empty?
        base = "#{base}/" unless base.end_with?("/")
        path = path[1..] if path.to_s.start_with?("/")
      end

      params = "?#{params}" if !params.nil? && !params.empty?
      "#{base}#{path}#{params}"
    end

    def auth?
      !user.to_s.empty? || !password.to_s.empty?
    end

    # Utilized as the parent directory for cached gems
    def host_id
      @host_id ||= "#{host}_#{hash}"
    end

    # Cache records need a distinct source per credential, but not the credential itself.
    def cache_uri
      return to_s unless @uri.userinfo

      clean = @uri.dup
      clean.user = clean.password = nil
      clean.fragment = host_id
      identity = clean.to_s
      identity.bytesize <= 191 ? identity : host_id
    end

    def user
      return URI::DEFAULT_PARSER.unescape(@uri.user) if @uri.user

      env_auth_user
    end

    def password
      return URI::DEFAULT_PARSER.unescape(@uri.password) if @uri.user && @uri.password
      return nil if @uri.user

      env_auth_pass
    end

    # Whether +other+ is the same gem source: the scheme, host, port and path
    # must match, while credentials and trailing slashes are ignored.
    def same_source?(other)
      source_key == other.source_key
    end

    def allowed?(config)
      allowed = Array(config[:allowed_upstreams])
      allowed.include?("*") || [config[:rubygems_url], *allowed].any? do |url|
        same_source?(Gemstash::Upstream.new(url))
      end
    end

    def self.allowed_redirect?(target, config)
      return false if target.userinfo || !%w[http https].include?(target.scheme) || !target.hostname

      path = URI::DEFAULT_PARSER.unescape(target.path)
      return false if path.split("/").include?("..")

      allowed = Array(config[:allowed_upstreams])
      allowed.include?("*") || [config[:rubygems_url], *allowed, *Array(config[:allowed_redirects])].any? do |url|
        source = Gemstash::Upstream.new(url)
        upgrade = source.scheme == "http" && target.scheme == "https"
        (target.scheme == source.scheme || upgrade) && target.hostname.downcase == source.uri.hostname.downcase &&
          (target.port == source.uri.port || (upgrade && target.port == 443)) &&
          path_within?(source.uri.path, target.path)
      end
    end

    # Whether +target_path+ is +source_path+ or lies below it, comparing whole
    # segments. A source without a path covers its host, so nothing is confined.
    def self.path_within?(source_path, target_path)
      prefix = source_path.sub(%r{/+\z}, "").gsub(/%\h\h/, &:upcase).split("/", -1)
      segments = target_path.gsub(/%\h\h/, &:upcase).split("/", -1)
      return true if prefix.size <= 1

      segments.first(prefix.size) == prefix && segments.drop(prefix.size).none? {|segment| ambiguous_segment?(segment) }
    end

    # A segment that some servers resolve differently from how it reads: a dot
    # segment (also behind a ";param" suffix), an escaped separator or control
    # character, or a second layer of escaping.
    def self.ambiguous_segment?(segment)
      decoded = URI::DEFAULT_PARSER.unescape(segment)
      decoded.sub(/;.*\z/m, "").match?(/\A\.\.?\z/) || decoded.match?(%r{[/\\\x00-\x1f\x7f]|%\h\h})
    end

    private_class_method :path_within?, :ambiguous_segment?

  protected

    def source_key
      [scheme, host.to_s.downcase, @uri.port, @uri.path.sub(%r{/+\z}, ""), @uri.query]
    end

  private

    def hash
      Digest::MD5.hexdigest(to_s)
    end

    def env_auth_user
      return unless env_auth

      env_auth.split(":", 2).first
    end

    def env_auth_pass
      return unless env_auth
      return unless env_auth.include?(":")

      env_auth.split(":", 2).last
    end

    def env_auth
      @env_auth ||= ENV["GEMSTASH_#{host_for_env}"]
    end

    def host_for_env
      host.upcase.gsub(".", "__").gsub("-", "___")
    end

    # :nodoc:
    class GemName
      def initialize(upstream, gem_name)
        @upstream = upstream
        @id = gem_name
      end

      def to_s
        name
      end

      def id
        @id
      end

      def name
        @name ||= @id.gsub(/\.gem(spec\.rz)?\z/, "")
      end
    end
  end
end
