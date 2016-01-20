require "digest"

module Gemstash
  #:nodoc:
  class Upstream
    extend Forwardable

    attr_reader :user_agent

    def_delegators :@uri, :scheme, :host, :user, :password, :to_s

    def initialize(upstream, user_agent: nil)
      @uri = URI(URI.decode(upstream.to_s))
      @user_agent = user_agent
      raise "URL '#{@uri}' is not valid!" unless @uri.to_s =~ URI.regexp
    end

    def url(path = nil, params = nil)
      base = to_s

      unless path.to_s.empty?
        base = "#{base}/" unless base.end_with?("/")
        path = path[1..-1] if path.to_s.start_with?("/")
      end

      params = "?#{params}" if !params.nil? && !params.empty?
      "#{base}#{path}#{params}"
    end

    def auth?
      !user.to_s.empty? && !password.to_s.empty?
    end

    # Utilized as the parent directory for cached gems
    def host_id
      @host_id ||= "#{host}_#{hash}"
    end

    def storage
      @storage ||= Gemstash::Storage.for("gem_cache").for(host_id)
    end

    def gem_name(name, type)
      Gemstash::Upstream::GemName.new(self, name, type)
    end

  private

    def hash
      Digest::MD5.hexdigest(to_s)
    end

    #:nodoc:
    class GemName
      attr_reader :name, :type, :upstream

      def initialize(upstream, gem_name, type)
        @upstream = upstream
        @type = type

        @name = if gem_name.is_a?(Array)
          from_spec_array(gem_name)
        else
          gem_name.gsub(/\.gem(spec\.rz)?$/i, "")
        end
      end

      def to_s
        name
      end

      def resource
        @resource ||= upstream.storage.resource(name)
      end

      def path
        case type
        when :gem
          "gems/#{name}.gem"
        when :spec
          "quick/Marshal.4.8/#{name}.gemspec.rz"
        else
          raise "Invalid type #{type.inspect}"
        end
      end

    private

      def from_spec_array(spec)
        raise "Expected spec array to be of length 3!" if spec.size != 3

        if spec[2] == "ruby"
          spec[0, 2].join("-")
        else
          spec.join("-")
        end
      end
    end
  end
end
