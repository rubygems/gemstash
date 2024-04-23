# frozen_string_literal: true

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
      url = CGI.unescape(upstream.to_s)
      url = "https://#{url}" unless %r{^https?://}.match?(url)
      @uri = URI(url)
      @user_agent = user_agent
      raise "URL '#{@uri}' is not valid!" unless @uri.to_s&.match?(URI::DEFAULT_PARSER.make_regexp)
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

    def user
      env_auth_user || @uri.user
    end

    def password
      env_auth_pass || @uri.password
    end

  private

    def hash
      Digest::SHA256.hexdigest(to_s)
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
        @name ||= @id.gsub(/\.gem(spec\.rz)?$/i, "")
      end
    end
  end
end
