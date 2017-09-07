Sequel.migration do
  up do
    alter_table :authorizations do
      add_column :name, String, :size => 191, :null => false, :default => ""
    end
  end
  down do
    alter_table :authorizations do
      drop_column :name
    end
  end
end
