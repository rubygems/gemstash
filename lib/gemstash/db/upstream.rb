# frozen_string_literal: true

module Gemstash
  module DB
    # Sequel model for upstreams table.
    class Upstream < Sequel::Model
      def self.find_or_insert(upstream)
        record = find_existing(upstream)
        return record.id if record

        new(uri: upstream.cache_uri, host_id: upstream.host_id).tap(&:save).id
      end

      def self.find_existing(upstream)
        record = self[uri: upstream.cache_uri]
        return record if record

        # A legacy encoded path may have this ID but represent a different
        # literal path. Do not let it serve that path's modern identity.
        if (record = self[host_id: upstream.host_id]) &&
            (record.uri == upstream.to_s || record.uri == upstream.cache_uri)
          record.update(uri: upstream.cache_uri) if record.uri != upstream.cache_uri
          return record
        end

        # Older releases decoded the entire URL before deriving the cache ID.
        legacy_uri = CGI.unescape(upstream.to_s)
        begin
          legacy_source = URI(legacy_uri)
          legacy_id = "#{legacy_source.host}_#{Digest::MD5.hexdigest(legacy_uri)}"
          if (record = self[uri: legacy_uri, host_id: legacy_id])
            record.update(uri: Gemstash::Upstream.new(legacy_source).cache_uri)
            return record if legacy_uri == upstream.to_s
          end
        rescue URI::InvalidURIError
          # A decoded URI that could not be parsed never had a legacy cache row.
        end

        nil
      end
    end
  end
end
