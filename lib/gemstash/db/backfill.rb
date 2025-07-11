module Gemstash
  module DB
    class Backfill < Sequel::Model
      def self.pending
        where(completed_at: nil)
      end

      def completed?
       !!completed_at
      end

      def self.compact_index
        where(backfill_class: "CompactIndexesBackfillRunner").first
      end

    end
  end
end
