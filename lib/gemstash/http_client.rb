# frozen_string_literal: true

require "gemstash"
require "faraday"
require "faraday_middleware"

module Gemstash
  # :nodoc:
  class WebError < StandardError
    attr_reader :code

    def initialize(message, code)
      @code = code
      super(message)
    end
  end

  # :nodoc:
  class ConnectionError < WebError
    def initialize(message)
      super(message, 502) # Bad Gateway
    end
  end

  # :nodoc:
  class HTTPClient
    extend Gemstash::Env::Helper
    include Gemstash::Env::Helper
    include Gemstash::Logging

    DEFAULT_USER_AGENT = "Gemstash/#{Gemstash::VERSION}"

    def self.for(upstream)
      url = upstream.uri.dup
      url.user = url.password = nil
      client = Faraday.new(url.to_s) do |config|
        config.use FaradayMiddleware::FollowRedirects, callback: method(:refuse_redirect)
        config.adapter :net_http
        config.options.timeout = gemstash_env.config[:fetch_timeout]
      end

      client.basic_auth(upstream.user, upstream.password) if upstream.auth?

      user_agent = "#{upstream.user_agent} " unless upstream.user_agent.to_s.empty?
      user_agent = user_agent.to_s + DEFAULT_USER_AGENT

      new(client, user_agent: user_agent)
    end

    def self.refuse_redirect(from, to)
      target = URI(to[:url].to_s)
      if !(from[:url].scheme == "https" && target.scheme != "https") &&
          Gemstash::Upstream.allowed_redirect?(target, gemstash_env.config)
        source = from[:url]
        to[:request_headers].delete("Authorization") if
          [source.scheme, source.hostname.downcase, source.port] != [target.scheme, target.hostname.downcase, target.port]
        return
      end

      log_target = "#{target.scheme}://#{target.hostname}:#{target.port}#{target.path}"
      Gemstash::Logging.logger.warn("Refusing upstream redirect to #{log_target}")
      raise Gemstash::WebError.new("Refusing an unlisted upstream redirect", 502)
    rescue URI::InvalidURIError, ArgumentError
      Gemstash::Logging.logger.warn("Refusing invalid upstream redirect")
      raise Gemstash::WebError.new("Refusing an invalid upstream redirect", 502)
    end

    attr_reader :client

    def initialize(client = nil, user_agent: nil)
      @client = client
      @user_agent = user_agent || DEFAULT_USER_AGENT
    end

    def get(path)
      response = with_retries do
        @client.get(path) do |req|
          req.headers["User-Agent"] = @user_agent
          req.options.open_timeout = gemstash_env.config[:open_timeout]
        end
      end

      raise Gemstash::WebError.new("Upstream returned HTTP #{response.status}", response.status) unless response.success?

      if block_given?
        yield(response.body, response.headers)
      else
        response.body
      end
    rescue URI::InvalidURIError
      raise Gemstash::WebError.new("Upstream sent an invalid redirect", 502)
    rescue Faraday::Error
      raise Gemstash::WebError.new("Upstream request failed", 502)
    end

  private

    def with_retries(times: 3)
      loop do
        times -= 1
        begin
          return yield
        rescue Faraday::ConnectionFailed => e
          log.warn "Upstream connection failure (#{e.class})"
          raise(ConnectionError, "Upstream connection failed") unless times > 0

          log.info "retrying... #{times} more times"
        end
      end
    end
  end
end
