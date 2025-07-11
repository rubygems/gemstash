module Gemstash
  module DB
    class Backfill < Sequel::Model
      def self.pending
        where(completed_at: nil)
      end
    end
  end
end
