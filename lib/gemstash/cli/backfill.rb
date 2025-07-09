module Gemstash
  class CLI
    class Backfill < Gemstash::CLI::Base
      def run
        Gemstash::Backfiller.new.run
      end
    end
  end
end