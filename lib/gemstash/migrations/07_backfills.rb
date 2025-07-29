# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :backfills do
      primary_key :id
      String :backfill_class
      Integer :affected_rows
      String :gemstash_version_introduced
      String :description
      DateTime :completed_at
    end
  end
end
