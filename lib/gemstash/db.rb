# frozen_string_literal: true

require "gemstash"

module Gemstash
  # Module containing the DB models.
  module DB
    raise "Gemstash::DB cannot be loaded until the Gemstash::Env is available" unless Gemstash::Env.available?

    Sequel::Model.db = Gemstash::Env.current.db
    Sequel::Model.raise_on_save_failure = true
    Sequel::Model.plugin :timestamps, update_on_create: true

    # Helpers shared by the DB models.
    module ModelHelpers
      # Run the insert in the block, unless a concurrent request inserted a row
      # matching +keys+ first, in which case return that row's id. The savepoint
      # keeps a failed insert from aborting an enclosing transaction (PostgreSQL).
      def insert_or_find(keys, &insert)
        db.transaction(savepoint: true, &insert)
      rescue Sequel::UniqueConstraintViolation
        record = self[keys]
        raise unless record

        record.id
      end
    end

    autoload :Authorization, "gemstash/db/authorization"
    autoload :CachedRubygem, "gemstash/db/cached_rubygem"
    autoload :Dependency,    "gemstash/db/dependency"
    autoload :Rubygem,       "gemstash/db/rubygem"
    autoload :Upstream,      "gemstash/db/upstream"
    autoload :Version,       "gemstash/db/version"
  end
end
