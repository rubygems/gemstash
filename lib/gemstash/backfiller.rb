require "rubygems/package"

module Gemstash
  class Backfiller
    include Gemstash::Env::Helper

    attr_reader :db

    def initialize
      @db = gemstash_env.db
    end

    def run
      if backfills.any?
        puts "Running #{backfills.count} backfills..."
      else
        puts "No backfills to run."
        return
      end

      backfills.each do |record|
        backfill_runner = Backfiller.const_get(record.backfill_class).new(db, storage)

        affected_rows = backfill_runner.records.count
        backfill_runner.run

        record.update(completed_at: Time.now, affected_rows: affected_rows)
      end
    end

    def run_specific_backfill(backfill_record)
      backfill_runner = Backfiller.const_get(backfill_record.backfill_class).new(db, storage)

      affected_rows = backfill_runner.records.count
      backfill_runner.run

      backfill_record.update(completed_at: Time.now, affected_rows: affected_rows)
    end

    def backfills
      DB::Backfill.pending
    end

    def needed?
      backfills.any?(&:needed?)
    end

    def storage
      @storage ||= Gemstash::Storage.for("private").for("gems")
    end

    class BackfillRunner
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

        failed_rows = 0
        records.each do |record|
          puts "#{record.class.name}##{record.id}..."
          begin
            backfill(record)
          rescue StandardError => e
            puts "Error backfilling #{record.class.name}##{record.id}"
            puts e.message
            puts e.backtrace.join("\n")
            failed_rows += 1
          end
        end

        if failed_rows > 0
          puts "Backfill failed for #{failed_rows} rows!"
          puts "Review the output and run the backfill again to fix the errors."
          puts "If you get this error again, please file an issue at https://github.com/rubygems/gemstash/issues with the output of this backfill."
        end

        puts "Done!"
      end

      def backfill(record)
        raise NotImplementedError
      end
    end

    class CompactIndexesBackfillRunner < BackfillRunner
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
