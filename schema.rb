# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:authorizations) do
      primary_key :id
      column :auth_key, "varchar(191)", :null => false
      column :permissions, "varchar(191)", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false
      column :name, "varchar(191)"

      index [:auth_key], :unique => true
      index [:name], :unique => true
    end

    create_table(:cached_rubygems) do
      primary_key :id
      column :upstream_id, "INTEGER", :null => false
      column :name, "varchar(191)", :null => false
      column :resource_type, "varchar(191)", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false

      index [:name]
      index %i[upstream_id resource_type name], :unique => true
    end

    create_table(:dependencies) do
      primary_key :id
      column :version_id, "INTEGER", :null => false
      column :rubygem_name, "varchar(191)", :null => false
      column :requirements, "varchar(191)", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false

      index [:rubygem_name]
      index [:version_id]
    end

    create_table(:health_tests) do
      primary_key :id
      column :string, "varchar(255)"
    end

    create_table(:rubygems) do
      primary_key :id
      column :name, "varchar(191)", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false

      index [:name], :unique => true
    end

    create_table(:schema_info) do
      column :version, "INTEGER", :default => 0, :null => false
    end

    create_table(:upstreams) do
      primary_key :id
      column :uri, "varchar(191)", :null => false
      column :host_id, "varchar(191)", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false

      index [:host_id], :unique => true
      index [:uri], :unique => true
    end

    create_table(:versions) do
      primary_key :id
      column :rubygem_id, "INTEGER", :null => false
      column :storage_id, "varchar(191)", :null => false
      column :number, "varchar(191)", :null => false
      column :platform, "varchar(191)", :null => false
      column :full_name, "varchar(191)", :null => false
      column :indexed, "boolean", :default => true, :null => false
      column :prerelease, "boolean", :null => false
      column :created_at, "timestamp", :null => false
      column :updated_at, "timestamp", :null => false
      column :info_checksum, "varchar(40)"
      column :sha256, "varchar(64)"
      column :required_ruby_version, "varchar(191)"
      column :required_rubygems_version, "varchar(191)"

      index [:full_name], :unique => true
      index [:indexed]
      index %i[indexed prerelease]
      index [:number]
      index %i[rubygem_id number platform], :unique => true
      index [:storage_id], :unique => true
    end
  end
end
