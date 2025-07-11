# frozen_string_literal: true

require "terminal-table"

module Gemstash
  class CLI
    # This implements the command line backfill task:
    #  $ gemstash backfill
    class Backfill < Gemstash::CLI::Base
      def run
        prepare

        if @cli.options[:list]
          list_backfills
        elsif @cli.options[:rerun]
          rerun_backfill
        else
          Gemstash::Backfiller.new.run
        end
      end

    private

      def list_backfills
        backfills = Gemstash::DB::Backfill.all
        if backfills.empty?
          @cli.say "No backfills found in the database."
          return
        end

        rows = backfills.map do |backfill|
          status = backfill.completed_at ? "Completed" : "Pending"
          completed_at = backfill.completed_at ? backfill.completed_at.strftime("%Y-%m-%d %H:%M:%S") : "N/A"
          backfill.affected_rows || "N/A"
          [
            backfill.backfill_class,
            status,
            completed_at,
            backfill.description
          ]
        end

        @cli.say Terminal::Table.new(
          headings: %w[Backfill Status Completed_At Description],
          rows: rows,
          style: { border_top: false, border_bottom: false, border_left: false, border_right: false }
        )
      end

      def rerun_backfill
        backfill_name = @cli.options[:rerun]
        backfill_record = Gemstash::DB::Backfill.find(backfill_class: backfill_name)

        unless backfill_record
          available_backfills = Gemstash::DB::Backfill.all.map(&:backfill_class).join(", ")
          raise Gemstash::CLI::Error.new(@cli, "Backfill '#{backfill_name}' not found.\nAvailable backfills: #{available_backfills}")
        end

        @cli.say "Re-running backfill: #{backfill_name}"

        # Reset the backfill to pending status
        backfill_record.update(completed_at: nil, affected_rows: nil)

        # Run the specific backfill
        backfiller = Gemstash::Backfiller.new
        backfiller.run_specific_backfill(backfill_record)
      end
    end
  end
end
