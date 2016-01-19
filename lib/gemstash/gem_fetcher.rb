require "gemstash"
require "set"

module Gemstash
  #:nodoc:
  class GemFetcher
    def initialize(storage, http_client)
      @storage = storage
      @http_client = http_client
      @valid_headers = Set.new(["etag", "content-type", "content-length", "last-modified"])
    end

    # Fetch the resource type for the +gem_name+, returning a Gemstash::Resource
    # where the resource is stored after fetching.
    #
    # @param gem_name [Gemstash::Upstream::GemName] the gem to fetch
    # @type type [Symbol] resource type, either :gem or :spec
    # @return [Gem::Resource] resource where the results are stored
    def fetch(gem_name, type)
      @http_client.get(path_for(gem_name.id, type)) do |body, headers|
        properties = filter_headers(headers)
        validate_download(body, properties)
        store(gem_name, type, body, properties)
      end
    end

  private

    def store(gem_name, type, body, properties)
      gem_resource = @storage.resource(gem_name.name)

      resource_properties = {
        upstream: gem_name.upstream.to_s,
        gem_name: gem_name.name,
        headers: { type => properties }
      }

      gem = gem_resource.save({ type => body }, resource_properties)
      Gemstash::DB::CachedRubygem.store(gem_name.upstream, gem_name, type)
      gem
    end

    def path_for(gem_id, type)
      case type
      when :gem
        "gems/#{gem_id}"
      when :spec
        "quick/Marshal.4.8/#{gem_id}"
      else
        raise "Invalid type #{type.inspect}"
      end
    end

    def filter_headers(headers)
      headers.inject({}) do|properties, (key, value)|
        properties[key.downcase] = value if @valid_headers.include?(key.downcase)
        properties
      end
    end

    def validate_download(content, headers)
      expected_size = content_length(headers)
      raise "Incomplete download, only #{body.length} was downloaded out of #{expected_size}" \
        if content.length < expected_size
    end

    def content_length(headers)
      headers["content-length"].to_i
    end
  end
end
