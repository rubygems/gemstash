require "rubygems/package"

module Gemstash
  class Backfiller
    def initialize
      @db = Gemstash::Env.current.db
    end

    def run
      backfills.each do |backfill|
        backfill.run
      end
    end


    def backfills
      @backfills ||= [
        CompactIndexesBackfill.new(@db, storage)
      ]
    end

    def needed?
      backfills.any?(&:needed?)
    end

    def storage
      @storage ||= Gemstash::Storage.for("private").for("gems")
    end

    class Backfill
      def initialize(db, storage)
        @db = db
        @storage = storage
      end

      def needed?
        records.count > 0
      end

      def records
        raise NotImplementedError
      end

      def run
        puts "Running backfill: #{self.class.name}"
        puts "Records: #{records.count}"
        records.each do |record|
          puts "#{record.class.name}##{record.id}: #{record.full_name}"
          backfill(record)
        end
      end

      def backfill(record)
        raise NotImplementedError
      end
    end

    class CompactIndexesBackfill < Backfill
      def records
        DB::Version.where(
          Sequel.or(
            info_checksum: nil,
            sha256: nil,
          )
        )
      end

      def backfill(record)
        resource = @storage.resource(record.storage_id)
        gem_contents = resource.content(:gem)  
        gem = Gem::Package.new(StringIO.new(gem_contents))

        sha256 = Digest::SHA256.base64digest(gem_contents)
        spec = gem.spec

        info = Gemstash::CompactIndexBuilder::Info.new(nil, record.rubygem.name).tap(&:build_result).result
        record.update(
          info_checksum: Digest::MD5.hexdigest(info),
          sha256: sha256,
          required_ruby_version: spec.required_ruby_version,
          required_rubygems_version: spec.required_rubygems_version
        )
      end
    end
  end
end