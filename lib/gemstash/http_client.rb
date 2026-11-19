# frozen_string_literal: true

require "gemstash"
require "faraday"
require "faraday_middleware"
require "net/http"

# Net::HTTP reads response headers and chunk-size lines into an unbounded
# buffer before Faraday's on_data callback can enforce the body limit.
module GemstashHTTPReadLimits
  # Net::BufferedIO's positional boolean is part of its API. Newer net-http
  # also passes a limit: keyword, which is far above Gemstash's own limit.
  # rubocop:disable Style/OptionalBooleanParameter
  def readuntil(terminator, ignore_eof = false, limit: nil)
    limits = Thread.current[:gemstash_http_limits]
    unless limits
      return limit ? super(terminator, ignore_eof, limit: limit) : super(terminator, ignore_eof)
    end

    offset = @rbuf_offset
    begin
      until (idx = @rbuf.index(terminator, offset))
        raise Gemstash::WebError.new("Upstream response headers are too large", 502) if @rbuf.bytesize - @rbuf_offset > 64 * 1024

        offset = @rbuf.bytesize
        rbuf_fill
      end
      length = idx + terminator.bytesize - @rbuf_offset
      raise Gemstash::WebError.new("Upstream response headers are too large", 502) if length > 64 * 1024

      if limits[:headers]
        limits[:metadata] += length
        raise Gemstash::WebError.new("Upstream response headers are too large", 502) if limits[:metadata] > 64 * 1024
      end

      rbuf_consume(length)
    rescue EOFError
      raise unless ignore_eof

      rbuf_consume
    end
  end
  # rubocop:enable Style/OptionalBooleanParameter

private

  def rbuf_fill
    limits = Thread.current[:gemstash_http_limits]
    return super unless limits

    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_after_grace = now - limits[:started] - limits[:grace]
      raise Gemstash::WebError.new("Upstream request timed out", 502) if now >= limits[:deadline] ||
        (elapsed_after_grace > 0 && limits[:bytes] < elapsed_after_grace * 1024)

      tmp = @rbuf_empty ? @rbuf : nil
      case result = @io.read_nonblock(Net::BufferedIO::BUFSIZE, tmp, exception: false)
      when String
        bytes = result.bytesize
        @rbuf_empty = false
        if result.equal?(tmp)
          @rbuf_offset = 0
        else
          @rbuf << result
          result.clear
        end
        limits[:bytes] += bytes
        return
      when :wait_readable, :wait_writable
        io = @io.to_io
        remaining = [@read_timeout, limits[:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC)].min
        raise Gemstash::WebError.new("Upstream request timed out", 502) if remaining <= 0

        ready = result == :wait_readable ? io.wait_readable(remaining) : io.wait_writable(remaining)
        raise Net::ReadTimeout, "Upstream read timed out" unless ready
      when nil
        raise EOFError, "end of file reached"
      end
    end
  end
end

Net::BufferedIO.prepend(GemstashHTTPReadLimits)

# Count only the status and header lines, not chunk-size lines.
module GemstashHTTPHeaderLimits
  def read_new(sock)
    limits = Thread.current[:gemstash_http_limits]
    limits[:headers] = true if limits
    super
  ensure
    limits[:headers] = false if limits
  end
end

Net::HTTPResponse.singleton_class.prepend(GemstashHTTPHeaderLimits)

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
      limit = gemstash_env.config[:max_upstream_bytes]
      streamed = nil

      previous_limits = Thread.current[:gemstash_http_limits]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Thread.current[:gemstash_http_limits] = { metadata: 0, headers: false, started: started,
                                                grace: gemstash_env.config[:fetch_timeout], bytes: 0,
                                                deadline: started + gemstash_env.config[:max_upstream_duration] }

      response = with_retries do
        @client.get(path) do |req|
          req.headers["User-Agent"] = @user_agent
          remaining = Thread.current[:gemstash_http_limits][:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Gemstash::WebError.new("Upstream request timed out", 502) if remaining <= 0

          req.options.open_timeout = [gemstash_env.config[:open_timeout], remaining].min
          req.options.timeout = [gemstash_env.config[:fetch_timeout], remaining].min
          streamed = stream_up_to(limit, req) if limit
        end
      end

      raise Gemstash::WebError.new("Upstream request timed out", 502) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > Thread.current[:gemstash_http_limits][:deadline]

      # A streamed body is not kept on the response
      body = streamed.to_s.empty? ? response.body : streamed
      raise too_large(limit) if limit && body.to_s.bytesize > limit
      raise Gemstash::WebError.new("Upstream returned HTTP #{response.status}", response.status) unless response.success?

      if block_given?
        yield(body, response.headers)
      else
        body
      end
    rescue Faraday::TimeoutError
      raise Gemstash::WebError.new("Upstream request timed out", 502)
    rescue URI::InvalidURIError
      raise Gemstash::WebError.new("Upstream sent an invalid redirect", 502)
    rescue Faraday::Error
      raise Gemstash::WebError.new("Upstream request failed", 502)
    ensure
      Thread.current[:gemstash_http_limits] = previous_limits
    end

  private

    # Collects the body as it arrives, so that a download larger than the limit
    # is aborted rather than buffered. Faraday restarts the count of received
    # bytes for each response, which includes any redirect being followed.
    def stream_up_to(limit, req)
      body = String.new(encoding: Encoding::BINARY)

      req.options.on_data = proc do |chunk, received|
        body.clear if received <= chunk.bytesize
        raise too_large(limit) if received > limit

        body << chunk
      end

      body
    end

    def too_large(limit)
      Gemstash::WebError.new("Upstream response is larger than the #{limit} bytes allowed by :max_upstream_bytes", 502)
    end

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
