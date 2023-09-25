# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table :authorizations do
      add_column :name, String, :size => 191
      add_index [:name], :unique => true
    end
  end
end
