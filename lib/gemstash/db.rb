# frozen_string_literal: true

require "gemstash"

module Gemstash
  # Module containing the DB models.
  module DB
    raise "Gemstash::DB cannot be loaded until the Gemstash::Env is available" unless Gemstash::Env.available?

    Sequel::Model.db = Gemstash::Env.current.db
    Sequel::Model.raise_on_save_failure = true
    Sequel::Model.plugin :timestamps, update_on_create: true
    Sequel::Model.db.extension :error_sql
    Sequel::Model.db.extension :string_agg
    Sequel::Model.db.extension :schema_dumper
    autoload :Authorization, "gemstash/db/authorization"
    autoload :CachedRubygem, "gemstash/db/cached_rubygem"
    autoload :Dependency,    "gemstash/db/dependency"
    autoload :Rubygem,       "gemstash/db/rubygem"
    autoload :Upstream,      "gemstash/db/upstream"
    autoload :Version,       "gemstash/db/version"
  end
end
