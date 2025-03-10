# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table :versions do # TODO: backfill info_checksum, sha256, required_ruby_version, required_rubygems_version
      add_column :info_checksum, String, :size => 40
      add_column :yanked_info_checksum, String, :size => 40
      add_column :yanked_at, DateTime, :null => true
      add_column :sha256, String, :size => 64
      add_column :required_ruby_version, String, :size => 255
      add_column :required_rubygems_version, String, :size => 255
    end
  end
end
