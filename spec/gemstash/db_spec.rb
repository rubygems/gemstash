# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gemstash::DB do
  let(:now) { Sequel::SQL::Constants::CURRENT_TIMESTAMP }

  # Make the model's first lookup miss and insert the row itself, the way a
  # concurrent request would between the lookup and the insert.
  def race_first_lookup(model)
    raced = false
    allow(model).to receive(:[]).and_wrap_original do |original, *args, **kwargs|
      next original.call(*args, **kwargs) if raced

      raced = true
      yield
      nil
    end
  end

  describe Gemstash::DB::Rubygem do
    let(:spec) { Gem::Specification.new {|s| s.name = "example" } }

    it "returns the existing row when another request inserts it first" do
      existing_id = nil
      race_first_lookup(Gemstash::DB::Rubygem) { existing_id = insert_rubygem("example") }

      # GemPusher calls this inside a transaction
      id = Gemstash::Env.current.db.transaction { Gemstash::DB::Rubygem.find_or_insert(spec) }
      expect(id).to eq(existing_id)
      expect(Gemstash::DB::Rubygem.where(name: "example").count).to eq(1)
    end
  end

  describe Gemstash::DB::Upstream do
    let(:upstream) { Gemstash::Upstream.new("https://rubygems.org") }

    it "returns the existing row when another request inserts it first" do
      existing_id = nil
      race_first_lookup(Gemstash::DB::Upstream) do
        existing_id = Gemstash::Env.current.db[:upstreams].insert(
          uri: upstream.to_s, host_id: upstream.host_id, created_at: now, updated_at: now
        )
      end

      id = Gemstash::Env.current.db.transaction { Gemstash::DB::Upstream.find_or_insert(upstream) }
      expect(id).to eq(existing_id)
      expect(Gemstash::DB::Upstream.where(uri: upstream.to_s).count).to eq(1)
    end
  end

  describe Gemstash::DB::CachedRubygem do
    let(:upstream) { Gemstash::Upstream.new("https://rubygems.org") }
    let(:gem_name) { Gemstash::Upstream::GemName.new(upstream, "rack") }

    it "returns the existing row when another request inserts it first" do
      upstream_id = Gemstash::DB::Upstream.find_or_insert(upstream)
      existing_id = nil
      race_first_lookup(Gemstash::DB::CachedRubygem) do
        existing_id = Gemstash::Env.current.db[:cached_rubygems].insert(
          upstream_id: upstream_id, name: "rack", resource_type: "gem", created_at: now, updated_at: now
        )
      end

      expect(Gemstash::DB::CachedRubygem.store(upstream, gem_name, :gem)).to eq(existing_id)
      expect(Gemstash::DB::CachedRubygem.where(upstream_id: upstream_id, name: "rack").count).to eq(1)
    end

    it "still raises unique constraint errors it can't resolve" do
      allow(Gemstash::DB::CachedRubygem).to receive(:[]).and_return(nil)
      Gemstash::DB::CachedRubygem.store(upstream, gem_name, :gem)

      expect { Gemstash::DB::CachedRubygem.store(upstream, gem_name, :gem) }.
        to raise_error(Sequel::UniqueConstraintViolation)
    end
  end
end
