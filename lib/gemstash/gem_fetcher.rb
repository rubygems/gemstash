require "gemstash"
require "set"

module Gemstash
  #:nodoc:
  class GemFetcher
    def initialize(http_client)
      @http_client = http_client
      @valid_headers = Set.new(["etag", "content-type", "content-length", "last-modified"])
    end

    # Fetch the resource for the +gem_name+, returning a Gemstash::Resource
    # where the resource is stored after fetching.
    #
    # @param gem_name [Gemstash::Upstream::GemName] the gem to fetch
    # @return [Gem::Resource] resource where the results are stored
    def fetch(gem_name)
      @http_client.get(gem_name.path) do |body, headers|
        properties = filter_headers(headers)
        validate_download(body, properties)
        store(gem_name, body, properties)
      end
    end

  private

    def store(gem_name, body, properties)
      resource_properties = {
        upstream: gem_name.upstream.to_s,
        gem_name: gem_name.name,
        headers: { gem_name.type => properties }
      }

      gem = gem_name.resource.save({ gem_name.type => body }, resource_properties)
      Gemstash::DB::CachedRubygem.store(gem_name)
      gem
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
