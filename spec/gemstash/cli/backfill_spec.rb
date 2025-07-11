# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::CLI::Backfill do
  before do
    # Don't let the environment change, else we get a separate test db
    allow(Gemstash::Env).to receive(:current=).and_return(nil)
  end

  let(:cli) do
    @said = ""
    result = double(options: cli_options)
    allow(result).to receive(:say) do |x|
      @said += x.to_s + "\n"
      nil
    end
    allow(result).to receive(:set_color) {|x| x }
    result
  end

  let(:cli_options) { {} }

  subject { described_class.new(cli) }

  context "with no options" do
    it "runs the normal backfill process" do
      backfiller = double("backfiller")
      expect(Gemstash::Backfiller).to receive(:new).and_return(backfiller)
      expect(backfiller).to receive(:run)
      subject.run
    end
  end

  context "with --list option" do
    let(:cli_options) { { list: true } }

    it "lists all backfills" do
      backfill_record = double(
        backfill_class: "TestBackfill",
        completed_at: Time.now,
        affected_rows: 5,
        description: "Test description"
      )
      allow(Gemstash::DB::Backfill).to receive(:all).and_return([backfill_record])
      subject.run
      expect(@said).to include("TestBackfill")
      expect(@said).to include("Completed")
      expect(@said).to include("Test description")
    end

    it "shows message when no backfills exist" do
      allow(Gemstash::DB::Backfill).to receive(:all).and_return([])
      subject.run
      expect(@said).to include("No backfills found in the database.")
    end
  end

  context "with --rerun option" do
    let(:backfill_name) { "TestBackfill" }
    let(:cli_options) { { rerun: backfill_name } }
    let(:backfill_record) { double(backfill_class: backfill_name) }

    it "reruns the specified backfill" do
      allow(Gemstash::DB::Backfill).to receive(:find).with(backfill_class: backfill_name).and_return(backfill_record)
      allow(backfill_record).to receive(:update)
      backfiller = double("backfiller")
      expect(Gemstash::Backfiller).to receive(:new).and_return(backfiller)
      expect(backfiller).to receive(:run_specific_backfill).with(backfill_record)
      subject.run
      expect(@said).to include("Re-running backfill: #{backfill_name}")
    end

    it "resets the backfill to pending status" do
      allow(Gemstash::DB::Backfill).to receive(:find).with(backfill_class: backfill_name).and_return(backfill_record)
      expect(backfill_record).to receive(:update).with(completed_at: nil, affected_rows: nil)
      backfiller = double("backfiller")
      allow(Gemstash::Backfiller).to receive(:new).and_return(backfiller)
      allow(backfiller).to receive(:run_specific_backfill)
      subject.run
    end

    it "raises error for non-existent backfill" do
      allow(Gemstash::DB::Backfill).to receive(:find).with(backfill_class: backfill_name).and_return(nil)
      allow(Gemstash::DB::Backfill).to receive(:all).and_return([])
      expect { subject.run }.to raise_error(Gemstash::CLI::Error, /Backfill 'TestBackfill' not found/)
    end

    it "shows available backfills in error message" do
      existing_backfill = double(backfill_class: "ExistingBackfill")
      allow(Gemstash::DB::Backfill).to receive(:find).with(backfill_class: backfill_name).and_return(nil)
      allow(Gemstash::DB::Backfill).to receive(:all).and_return([existing_backfill])
      expect { subject.run }.to raise_error(Gemstash::CLI::Error, /Available backfills: ExistingBackfill/)
    end
  end
end
