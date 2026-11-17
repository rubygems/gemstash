# frozen_string_literal: true

require "gemstash"

module Gemstash
  module DB
    # Sequel model for cached_rubygems table.
    class CachedRubygem < Sequel::Model
      extend ModelHelpers

      def self.store(upstream, gem_name, resource_type)
        db.transaction do
          upstream_id = Gemstash::DB::Upstream.find_or_insert(upstream)
          keys = { upstream_id: upstream_id, name: gem_name.name, resource_type: resource_type.to_s }
          record = self[keys]
          return record.id if record

          insert_or_find(keys) { new(keys).tap(&:save).id }
        end
      end
    end
  end
end
