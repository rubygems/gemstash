# frozen_string_literal: true

Sequel.migration do
  up do
    from(:backfills).insert(
      backfill_class: "CompactIndexesBackfillRunner",
      gemstash_version_introduced: "2.9.0",
      description: "Update existing versions to include information needed for compact indexes",
      completed_at: nil,
      affected_rows: nil
    )
  end

  down do
    from(:backfills).where(backfill_class: "CompactIndexesBackfillRunner").delete
  end
end
