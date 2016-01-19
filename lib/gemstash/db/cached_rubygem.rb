require "gemstash"

module Gemstash
  module DB
    # Sequel model for cached_rubygems table.
    class CachedRubygem < Sequel::Model
      def self.store(gem_name)
        db.transaction do
          upstream_id = Gemstash::DB::Upstream.find_or_insert(gem_name.upstream)
          record = self[upstream_id: upstream_id, name: gem_name.name, resource_type: gem_name.type.to_s]
          return record.id if record
          new(upstream_id: upstream_id, name: gem_name.name, resource_type: gem_name.type.to_s).tap(&:save).id
        end
      end
    end
  end
end
